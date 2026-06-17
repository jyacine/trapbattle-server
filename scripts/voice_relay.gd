extends Node
class_name VoiceManager

# Voice relay on the dedicated server.
#  • WebSocket path  — clients send _rpc_voice; we rebroadcast via _rpc_play_voice.
#  • WebRTC path     — when a client enables USE_WEBRTC it negotiates an
#    unreliable/unordered DataChannel to us (signaling over the reliable RPCs
#    below); we forward each speaker's audio to the other peers. STAR topology
#    (clients never connect to each other → no peer IP exposure).
#
# REQUIRES the `webrtc-native` GDExtension in the headless server build for the
# WebRTC path to function — WebRTCPeerConnection is a non-functional stub without
# it. The WebSocket path needs no addon, and until a peer's DataChannel is OPEN we
# keep relaying that peer over WebSocket, so this file is safe to ship before the
# addon is deployed (WebRTC simply stays dormant / falls back).
#
# The node MUST be named "VoiceManager" at "Main/VoiceManager" and declare the
# IDENTICAL @rpc method set (same sorted order + decorators) as the client's
# voice_manager.gd — Godot routes RPCs by sorted index, not name.

const USE_WEBRTC := true   # answer offers; no-op until clients offer AND the addon is present
const RTC_STUN   := "stun:stun.l.google.com:19302"
const RTC_CH_ID  := 1      # negotiated DataChannel id — MUST match the client

var _pcs: Dictionary = {}   # peer_id -> WebRTCPeerConnection
var _chs: Dictionary = {}   # peer_id -> WebRTCDataChannel

func _ready() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _on_peer_disconnected(pid: int) -> void:
	_pcs.erase(pid)
	_chs.erase(pid)

# ── WebSocket relay ───────────────────────────────────────────────────────────
## Client → server: receive audio and relay to all other clients (WS path).
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_voice(audio_bytes: PackedByteArray, sender_id: int) -> void:
	_rpc_play_voice.rpc(audio_bytes, sender_id)

## Server → all clients: play incoming audio. Runs on clients only here.
@rpc("authority", "call_remote", "unreliable")
func _rpc_play_voice(_audio_bytes: PackedByteArray, _sender_id: int) -> void:
	pass   # stub — runs on clients only

# ── WebRTC signaling (IDENTICAL set/order/decorators as the client) ───────────
## Server → client: SDP answer. Sent from here; handled on the client.
@rpc("authority", "call_remote", "reliable")
func _rpc_voice_answer(_sdp: String) -> void:
	pass   # stub — runs on clients only

## Trickle ICE, both directions (any_peer so it can flow server→client too).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_ice(media: String, index: int, name: String) -> void:
	if not USE_WEBRTC: return
	var pid := multiplayer.get_remote_sender_id()
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc != null:
		pc.add_ice_candidate(media, index, name)

## Client → server: SDP offer for the voice DataChannel. Create the peer
## connection (if new) and produce an answer.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_offer(sdp: String) -> void:
	if not USE_WEBRTC: return
	var pid := multiplayer.get_remote_sender_id()
	_ensure_pc(pid)
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc != null:
		pc.set_remote_description("offer", sdp)

# ── WebRTC peer lifecycle ─────────────────────────────────────────────────────
func _ensure_pc(pid: int) -> void:
	if _pcs.has(pid):
		return
	var pc := WebRTCPeerConnection.new()
	if pc.initialize({ "iceServers": [ { "urls": [RTC_STUN] } ] }) != OK:
		push_warning("[voice] server WebRTC init failed for peer %d (addon missing?)" % pid)
		return
	pc.session_description_created.connect(_on_pc_sdp.bind(pid))
	pc.ice_candidate_created.connect(_on_pc_ice.bind(pid))
	# Negotiated channel: both sides create id=RTC_CH_ID, unreliable + unordered.
	var ch := pc.create_data_channel("voice",
		{ "negotiated": true, "id": RTC_CH_ID, "ordered": false, "maxRetransmits": 0 })
	if ch != null:
		ch.write_mode = WebRTCDataChannel.WRITE_MODE_BINARY
	_pcs[pid] = pc
	_chs[pid] = ch

func _on_pc_sdp(type: String, sdp: String, pid: int) -> void:
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc == null:
		return
	pc.set_local_description(type, sdp)
	if type == "answer":
		_rpc_voice_answer.rpc_id(pid, sdp)

func _on_pc_ice(media: String, index: int, name: String, pid: int) -> void:
	_rpc_voice_ice.rpc_id(pid, media, index, name)

# ── Poll + forward ────────────────────────────────────────────────────────────
func _process(_delta: float) -> void:
	if _pcs.is_empty():
		return
	for pid in _pcs.keys():
		var pc: WebRTCPeerConnection = _pcs[pid]
		if pc == null:
			continue
		pc.poll()
		var ch: WebRTCDataChannel = _chs.get(pid)
		if ch == null:
			continue
		while ch.get_available_packet_count() > 0:
			_forward(pid, ch.get_packet())

# Forward one speaker's packet to every OTHER peer: WebRTC channel if open, else
# the WebSocket relay (so WebRTC and WS-only clients still hear each other).
func _forward(sender_id: int, audio: PackedByteArray) -> void:
	var framed := PackedByteArray()
	framed.resize(4)
	framed.encode_s32(0, sender_id)      # [sender_id i32 LE][ADPCM...]
	framed.append_array(audio)
	var net = get_parent().get_node_or_null("NetworkManager")
	var peers: Array = net._peers if net != null else _chs.keys()
	for pid in peers:
		if pid == sender_id:
			continue
		var ch: WebRTCDataChannel = _chs.get(pid)
		if ch != null and ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			ch.put_packet(framed)
		else:
			_rpc_play_voice.rpc_id(pid, audio, sender_id)

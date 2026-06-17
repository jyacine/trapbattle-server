extends Node
class_name VoiceManager

# Voice relay running on the dedicated server.
#
# Two transports, selected by USE_WEBRTC:
#   * WebSocket (default): clients send _rpc_voice (reliable WS), server rebroadcasts
#     via _rpc_play_voice. Simple, but rides TCP → choppy under loss.
#   * WebRTC DataChannel: each client negotiates an UNRELIABLE/UNORDERED DataChannel
#     to this server (signaling rides the reliable RPC channel). The server forwards
#     each speaker's audio to the other peers over their channels — a STAR relay
#     (no P2P mesh, no client IPs exposed). This removes TCP head-of-line blocking.
#
# The node MUST be named "VoiceManager" at path "Main/VoiceManager" so RPC routing
# resolves the same node path as on the client, and the @rpc method SET + decorators
# here MUST match the client's voice_manager.gd exactly (Godot indexes @rpc methods
# by position in the sorted list — a mismatch misroutes every call).
#
# REQUIREMENT for USE_WEBRTC=true: this headless server build must include the
# `webrtc-native` GDExtension (the web client has WebRTC built in; native/headless
# does not). Without it, WebRTCPeerConnection is a non-functional stub and clients
# transparently fall back to the WebSocket path.

const USE_WEBRTC := false
const RTC_STUN   := "stun:stun.l.google.com:19302"
const RTC_CH_ID  := 1            # negotiated DataChannel id — MUST match the client

# peer_id → WebRTCPeerConnection / WebRTCDataChannel
var _pcs: Dictionary = {}
var _chs: Dictionary = {}

func _ready() -> void:
	if USE_WEBRTC and multiplayer.has_multiplayer_peer():
		multiplayer.peer_disconnected.connect(_on_peer_gone)

func _process(_delta: float) -> void:
	if not USE_WEBRTC:
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
			_relay(pid, ch.get_packet())

# ── Voice payload RPCs ────────────────────────────────────────────────────────

## Client → server: receive audio and relay to all other clients.
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_voice(audio_bytes: PackedByteArray, sender_id: int) -> void:
	if USE_WEBRTC:
		_relay(sender_id, audio_bytes)          # mixed WebRTC/WS routing
	else:
		_rpc_play_voice.rpc(audio_bytes, sender_id)   # original WS broadcast

## Server → all clients: MUST match the client decorator exactly.
@rpc("authority", "call_remote", "unreliable")
func _rpc_play_voice(_audio_bytes: PackedByteArray, _sender_id: int) -> void:
	pass   # stub — runs on clients only

# ── Signaling RPCs (ride the reliable channel) ────────────────────────────────
# Same set + decorators + relative order as the client's voice_manager.gd.

## Client → server: SDP offer for the voice DataChannel.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_offer(sdp: String) -> void:
	if not USE_WEBRTC:
		return
	var pid := multiplayer.get_remote_sender_id()
	_ensure_pc(pid)
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc != null:
		pc.set_remote_description("offer", sdp)   # → emits the answer

## Server → client: SDP answer (server sends via rpc_id; stub here).
@rpc("authority", "call_remote", "reliable")
func _rpc_voice_answer(_sdp: String) -> void:
	pass   # client-only handler

## Trickle ICE, both directions.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_ice(media: String, index: int, name: String) -> void:
	if not USE_WEBRTC:
		return
	var pid := multiplayer.get_remote_sender_id()
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc != null:
		pc.add_ice_candidate(media, index, name)

# ── WebRTC peer lifecycle ─────────────────────────────────────────────────────
func _ensure_pc(pid: int) -> void:
	if _pcs.has(pid):
		return
	var pc := WebRTCPeerConnection.new()
	if pc.initialize({ "iceServers": [ { "urls": [RTC_STUN] } ] }) != OK:
		push_warning("[voice] server WebRTC init failed for peer %d" % pid)
		return
	pc.session_description_created.connect(_on_pc_sdp.bind(pid))
	pc.ice_candidate_created.connect(_on_pc_ice.bind(pid))
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

func _on_peer_gone(pid: int) -> void:
	_pcs.erase(pid)
	_chs.erase(pid)

# ── Forwarding ────────────────────────────────────────────────────────────────
# Send `sender_id`'s audio to every other connected peer: over its WebRTC channel
# (prefixed with the sender id) when open, else over the WebSocket RPC. This lets
# WebRTC and WebSocket clients share a room during rollout.
func _relay(sender_id: int, audio: PackedByteArray) -> void:
	var prefixed := PackedByteArray()
	prefixed.resize(4)
	prefixed.encode_s32(0, sender_id)
	prefixed.append_array(audio)
	for pid in multiplayer.get_peers():
		if pid == sender_id:
			continue
		var ch: WebRTCDataChannel = _chs.get(pid)
		if ch != null and ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			ch.put_packet(prefixed)
		else:
			_rpc_play_voice.rpc_id(pid, audio, sender_id)

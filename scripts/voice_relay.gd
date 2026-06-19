extends Node
class_name VoiceManager

const USE_WEBRTC := true
const RTC_STUN   := "stun:stun.l.google.com:19302"
const RTC_CH_ID  := 1

# Relay tuning
const MAX_IN_PKTS_PER_PEER_PER_FRAME := 6      # prevent frame spikes
const MAX_CH_BACKLOG_PKTS            := 12     # drop-old strategy threshold
const MIN_VOICE_PACKET_BYTES         := 8      # sanity floor
const MAX_VOICE_PACKET_BYTES         := 1600   # sanity cap (fits MTU-friendly payloads)

var _pcs:      Dictionary = {}   # pid -> WebRTCPeerConnection
var _chs:      Dictionary = {}   # pid -> WebRTCDataChannel
var _ch_open:  Dictionary = {}   # pid -> bool  (tracks DataChannel open transitions)

func _ready() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _on_peer_disconnected(pid: int) -> void:
	var had_rtc: bool = _pcs.has(pid)
	var ch_was_open: bool = _ch_open.get(pid, false)
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc != null:
		pc.close()
	_pcs.erase(pid)
	_chs.erase(pid)
	_ch_open.erase(pid)
	if had_rtc:
		Logger.info("Voice: WebRTC session closed for peer %d (channel was %s)" % [
			pid, "OPEN" if ch_was_open else "not yet open"])

@rpc("any_peer", "call_remote", "unreliable")
func _rpc_voice(audio_bytes: PackedByteArray, sender_id: int) -> void:
	if audio_bytes.size() < MIN_VOICE_PACKET_BYTES or audio_bytes.size() > MAX_VOICE_PACKET_BYTES:
		return
	_rpc_play_voice.rpc(audio_bytes, sender_id)

@rpc("authority", "call_remote", "unreliable")
func _rpc_play_voice(_audio_bytes: PackedByteArray, _sender_id: int) -> void:
	pass

@rpc("authority", "call_remote", "reliable")
func _rpc_voice_answer(_sdp: String) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_ice(media: String, index: int, name: String) -> void:
	if not USE_WEBRTC: return
	var pid := multiplayer.get_remote_sender_id()
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc != null:
		pc.add_ice_candidate(media, index, name)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_offer(sdp: String) -> void:
	if not USE_WEBRTC: return
	var pid := multiplayer.get_remote_sender_id()
	Logger.info("Voice: WebRTC offer received from peer %d" % pid)
	_ensure_pc(pid)
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc != null:
		pc.set_remote_description("offer", sdp)

func _ensure_pc(pid: int) -> void:
	if _pcs.has(pid):
		return

	var pc := WebRTCPeerConnection.new()
	if pc.initialize({ "iceServers": [ { "urls": [RTC_STUN] } ] }) != OK:
		Logger.warn("Voice: WebRTC peer connection init failed for peer %d" % pid)
		return

	Logger.info("Voice: WebRTC peer connection created for peer %d" % pid)
	pc.session_description_created.connect(_on_pc_sdp.bind(pid))
	pc.ice_candidate_created.connect(_on_pc_ice.bind(pid))

	var ch := pc.create_data_channel("voice", {
		"negotiated": true,
		"id": RTC_CH_ID,
		"ordered": false,
		"maxRetransmits": 0
	})
	if ch != null:
		ch.write_mode = WebRTCDataChannel.WRITE_MODE_BINARY

	_pcs[pid] = pc
	_chs[pid] = ch
	_ch_open[pid] = false

func _on_pc_sdp(type: String, sdp: String, pid: int) -> void:
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc == null: return
	pc.set_local_description(type, sdp)
	if type == "answer":
		Logger.info("Voice: WebRTC answer sent to peer %d" % pid)
		_rpc_voice_answer.rpc_id(pid, sdp)

func _on_pc_ice(media: String, index: int, name: String, pid: int) -> void:
	_rpc_voice_ice.rpc_id(pid, media, index, name)

func _process(_delta: float) -> void:
	if _pcs.is_empty():
		return

	# Poll all PCs first
	for pid in _pcs.keys():
		var pc: WebRTCPeerConnection = _pcs.get(pid)
		if pc != null:
			pc.poll()

	# Read with budget to avoid burst spikes
	for pid in _chs.keys():
		var ch: WebRTCDataChannel = _chs.get(pid)
		if ch == null:
			continue

		# Log DataChannel open transition (fires once per peer)
		var is_open: bool = ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN
		if is_open and not _ch_open.get(pid, false):
			_ch_open[pid] = true
			Logger.info("Voice: DataChannel OPEN for peer %d — UDP relay active" % pid)

		if not is_open:
			continue

		# Drop old backlog first (real-time freshness over completeness)
		var backlog := ch.get_available_packet_count()
		while backlog > MAX_CH_BACKLOG_PKTS:
			ch.get_packet() # discard oldest
			backlog -= 1

		var processed := 0
		while ch.get_available_packet_count() > 0 and processed < MAX_IN_PKTS_PER_PEER_PER_FRAME:
			var pkt := ch.get_packet()
			if pkt.size() >= MIN_VOICE_PACKET_BYTES and pkt.size() <= MAX_VOICE_PACKET_BYTES:
				_forward(pid, pkt)
			processed += 1

func _forward(sender_id: int, audio: PackedByteArray) -> void:
	var framed := PackedByteArray()
	framed.resize(4)
	framed.encode_s32(0, sender_id)
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

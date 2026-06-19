extends Node
class_name VoiceManager

const USE_WEBRTC := true
# Google STUN is unreachable from this server (outbound UDP blocked, errno=101).
# Peer connections still open via host candidates (direct IP), but srflx discovery
# fails silently.  Add a TURN server here once credentials are available.
# stun.l.google.com can resolve to IPv6, causing ENETUNREACHABLE (errno=101) on
# servers with no IPv6 routing.  Use the numeric IPv4 address of a reliable STUN
# server to guarantee IPv4 is used.  74.125.250.129 = stun.l.google.com IPv4.
const RTC_STUN   := "stun:74.125.250.129:19302"
const RTC_CH_ID  := 1

# Relay tuning
const MAX_IN_PKTS_PER_PEER_PER_FRAME := 6      # prevent frame spikes
const MAX_CH_BACKLOG_PKTS            := 12     # drop-old strategy threshold
const MIN_VOICE_PACKET_BYTES         := 8      # sanity floor
const MAX_VOICE_PACKET_BYTES         := 1600   # sanity cap (fits MTU-friendly payloads)

# Diagnostic: log first WebSocket fallback per peer so we can see who isn't on UDP.
const WS_FALLBACK_LOG_INTERVAL := 10.0   # seconds between repeated fallback warnings

var _pcs:              Dictionary = {}   # pid -> WebRTCPeerConnection
var _chs:              Dictionary = {}   # pid -> WebRTCDataChannel
var _ch_open:          Dictionary = {}   # pid -> bool  (tracks DataChannel open transitions)
var _ws_fallback_t:    Dictionary = {}   # pid -> float (last time we logged WS fallback)
var _ws_pkt_count:     Dictionary = {}   # pid -> int   (WS packets since last log)
var _rtc_pkt_count:    Dictionary = {}   # pid -> int   (DataChannel packets since last log)
var _stats_timer:      float      = 0.0

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
		GameLogger.info("Voice: WebRTC session closed for peer %d (channel was %s)" % [
			pid, "OPEN" if ch_was_open else "not yet open"])

@rpc("any_peer", "call_remote", "unreliable")
func _rpc_voice(audio_bytes: PackedByteArray, sender_id: int) -> void:
	if audio_bytes.size() < MIN_VOICE_PACKET_BYTES or audio_bytes.size() > MAX_VOICE_PACKET_BYTES:
		return
	# This packet arrived via WebSocket (not WebRTC DataChannel) — log the first
	# occurrence and then periodically so we can see who is stuck on the slow path.
	var pid := multiplayer.get_remote_sender_id()
	_ws_pkt_count[pid] = _ws_pkt_count.get(pid, 0) + 1
	var now: float = Time.get_ticks_msec() * 0.001
	var last_t: float = _ws_fallback_t.get(pid, -WS_FALLBACK_LOG_INTERVAL)
	if (now - last_t) >= WS_FALLBACK_LOG_INTERVAL:
		_ws_fallback_t[pid] = now
		var ch: WebRTCDataChannel = _chs.get(pid)
		var ch_state: String = "no DataChannel"
		if ch != null:
			var s: int = ch.get_ready_state()
			ch_state = ["CONNECTING","OPEN","CLOSING","CLOSED"][s] if s < 4 else str(s)
		GameLogger.warn("Voice: peer %d audio via WebSocket fallback (DataChannel=%s) — UDP path not working" % [pid, ch_state])
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
	GameLogger.info("Voice: ICE candidate (peer %d→server)  %s" % [pid, _ice_info(name)])
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc != null:
		pc.add_ice_candidate(media, index, name)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_offer(sdp: String) -> void:
	if not USE_WEBRTC: return
	var pid := multiplayer.get_remote_sender_id()
	GameLogger.info("Voice: WebRTC offer received from peer %d" % pid)
	_ensure_pc(pid)
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc != null:
		pc.set_remote_description("offer", sdp)

# Parse "typ host/srflx/relay" and the candidate IP:port from an ICE candidate string.
# Candidate format: "candidate:<found> <comp> <proto> <prio> <ip> <port> typ <type> ..."
static func _ice_info(candidate: String) -> String:
	var parts := candidate.split(" ")
	var ip   := parts[4] if parts.size() > 4 else "?"
	var port := parts[5] if parts.size() > 5 else "?"
	var typ  := "?"
	for i in range(parts.size() - 1):
		if parts[i] == "typ":
			typ = parts[i + 1]
			break
	return "%s  %s:%s" % [typ, ip, port]

func _ensure_pc(pid: int) -> void:
	if _pcs.has(pid):
		return

	var pc := WebRTCPeerConnection.new()
	if pc.initialize({ "iceServers": [ { "urls": [RTC_STUN] } ] }) != OK:
		GameLogger.warn("Voice: WebRTC peer connection init failed for peer %d" % pid)
		return

	GameLogger.info("Voice: WebRTC peer connection created for peer %d" % pid)
	pc.session_description_created.connect(_on_pc_sdp.bind(pid))
	pc.ice_candidate_created.connect(_on_pc_ice.bind(pid))
	pc.connection_state_changed.connect(_on_pc_state_changed.bind(pid))

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
		GameLogger.info("Voice: WebRTC answer sent to peer %d" % pid)
		_rpc_voice_answer.rpc_id(pid, sdp)

func _on_pc_state_changed(pid: int) -> void:
	var pc: WebRTCPeerConnection = _pcs.get(pid)
	if pc == null: return
	var state_names := ["NEW", "CONNECTING", "CONNECTED", "DISCONNECTED", "FAILED", "CLOSED"]
	var s: int = pc.get_connection_state()
	var label: String = state_names[s] if s < state_names.size() else str(s)
	if s == WebRTCPeerConnection.STATE_CONNECTED:
		GameLogger.info("Voice: WebRTC CONNECTED to peer %d" % pid)
	elif s == WebRTCPeerConnection.STATE_FAILED:
		GameLogger.warn("Voice: WebRTC FAILED for peer %d — voice will fall back to WebSocket relay" % pid)
	elif s == WebRTCPeerConnection.STATE_DISCONNECTED:
		GameLogger.warn("Voice: WebRTC DISCONNECTED for peer %d" % pid)
	else:
		GameLogger.info("Voice: WebRTC state → %s  peer=%d" % [label, pid])

func _on_pc_ice(media: String, index: int, name: String, pid: int) -> void:
	# Log the server's own ICE candidates so we can see what IP/path is being offered.
	GameLogger.info("Voice: ICE candidate (server→peer %d)  %s" % [pid, _ice_info(name)])
	_rpc_voice_ice.rpc_id(pid, media, index, name)

func _process(delta: float) -> void:
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
			GameLogger.info("Voice: DataChannel OPEN for peer %d — UDP relay active" % pid)

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
				_rtc_pkt_count[pid] = _rtc_pkt_count.get(pid, 0) + 1
				_forward(pid, pkt)
			processed += 1

	# Periodic stats: show UDP vs WebSocket packet counts per active peer.
	_stats_timer += delta
	if _stats_timer >= 15.0:
		_stats_timer = 0.0
		var all_pids: Array = []
		for pid in _ws_pkt_count.keys(): if not all_pids.has(pid): all_pids.append(pid)
		for pid in _rtc_pkt_count.keys(): if not all_pids.has(pid): all_pids.append(pid)
		for pid in all_pids:
			var rtc: int = _rtc_pkt_count.get(pid, 0)
			var ws:  int = _ws_pkt_count.get(pid, 0)
			var path: String = "UDP/DataChannel" if rtc > 0 else "WebSocket only"
			GameLogger.info("Voice stats peer %d — path=%s  rtc_pkts=%d  ws_pkts=%d" % [pid, path, rtc, ws])
		_ws_pkt_count.clear()
		_rtc_pkt_count.clear()

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

extends Node
class_name NetworkManager

signal lobby_ready(seed_val: int, map_id: int)
signal peer_left(pid: int)

# Plain ws on localhost only. Caddy terminates TLS (wss) on the public ports
# (443 primary, 9999 legacy) and reverse-proxies to this backend port. We do NOT
# use Godot's embedded TLS — its mbedTLS server resets browser connections
# (mbedtls -0x6c00). See deploy notes.
const PORT := 9998

# Ordered peer list — index = player_index
var _peers: Array = []

# Assignments: peer_id -> player_index (populated on start)
var assignments: Dictionary = {}

# Map id chosen by the captain for the current match (relayed to all clients).
var _game_map: int = 1

# Player identity info sent by each client at connect time
var _names: Dictionary = {}   # peer_id -> name string
var _prefs: Dictionary = {}   # peer_id -> preferred color index

# True from the moment a match starts until the last player disconnects. While
# true, newly connecting peers are rejected (they can't join a match in progress).
# Resets to false when _peers empties so the next group can form a fresh lobby.
var game_started: bool = false

func start_server() -> void:
	var peer = WebSocketMultiplayerPeer.new()
	# Bind to loopback only: the public wss:// endpoint is fronted by Caddy, which
	# proxies to this plain-ws backend. Nothing external should hit 9998 directly.
	var err = peer.create_server(PORT, "127.0.0.1")
	if err != OK:
		GameLogger.error("Failed to start WebSocket server on port %d (err %d)" % [PORT, err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	GameLogger.info("WebSocket backend listening on 127.0.0.1:%d  (max %d players, TLS via Caddy)" % [
		PORT, Config.MAX_PLAYERS])

func _on_peer_connected(id: int) -> void:
	if game_started:
		# A match is already running. Don't add this peer to the lobby; the actual
		# rejection (notify + disconnect) happens once they send _rpc_join_info.
		GameLogger.info("Peer %d connected mid-match — will be rejected (game in progress)" % id)
		return
	_peers.append(id)
	GameLogger.info("Peer %d connected  (%d/%d slots filled)" % [id, _peers.size(), Config.MAX_PLAYERS])
	_rpc_lobby_update.rpc(Array(_peers), _names, _prefs)

func _on_peer_disconnected(id: int) -> void:
	var name_str: String = _names.get(id, "<no name yet>")
	GameLogger.info("Peer %d ('%s') disconnected  (%d peers remaining)" % [
		id, name_str, _peers.size() - 1])
	_peers.erase(id)
	assignments.erase(id)
	_names.erase(id)
	_prefs.erase(id)
	_rpc_peer_left.rpc(id)
	_rpc_lobby_update.rpc(Array(_peers), _names, _prefs)
	peer_left.emit(id)
	# Once everyone has left, drop back to "lobby" so a fresh group can start a new
	# match (otherwise game_started would stay true forever and reject all joiners).
	if _peers.is_empty():
		game_started = false
		GameLogger.info("All players left — server reset to lobby (accepting new players)")

# ── Captain requests to start ─────────────────────────────────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_start(map_id: int) -> void:
	if not multiplayer.is_server(): return
	if _peers.size() < 1:
		GameLogger.warn("Start requested but no players connected — ignored")
		return
	_game_map = map_id
	GameLogger.info("Start requested by peer %d  (map=%d)" % [multiplayer.get_remote_sender_id(), map_id])
	_do_start()

func _do_start() -> void:
	var s = randi()
	assignments.clear()

	# Two-pass color assignment: first honor client preferences, then fill remaining
	var taken: Dictionary = {}
	var done:  Dictionary = {}

	for pid in _peers:
		var pref = _prefs.get(pid, -1)
		if pref >= 0 and pref < Config.MAX_PLAYERS and not taken.has(pref):
			assignments[pid] = pref
			taken[pref] = true
			done[pid]   = true

	var next_slot = 0
	for pid in _peers:
		if done.get(pid, false): continue
		while taken.has(next_slot):
			next_slot += 1
		assignments[pid] = next_slot
		taken[next_slot] = true
		next_slot += 1

	game_started = true
	GameLogger.info("Starting game — seed=%d  map=%d  assignments=%s" % [s, _game_map, str(assignments)])
	_rpc_start_game.rpc(s, assignments, _game_map)
	lobby_ready.emit(s, _game_map)

# ── Client sends name and color preference at connect time ────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_info(name: String, color_idx: int) -> void:
	var sender = multiplayer.get_remote_sender_id()
	if game_started:
		# Reject: the match is already running. Tell the client (it shows a message
		# then returns to the menu), then disconnect after a short delay so the
		# reliable RPC has time to land before the socket closes.
		GameLogger.info("Rejecting peer %d ('%s') — game already in progress" % [sender, name])
		_rpc_game_in_progress.rpc_id(sender)
		get_tree().create_timer(1.5).timeout.connect(func():
			if multiplayer.has_multiplayer_peer():
				multiplayer.multiplayer_peer.disconnect_peer(sender))
		return
	_names[sender] = name
	_prefs[sender] = color_idx
	GameLogger.info("Peer %d identified — name='%s'  color_slot=%d" % [sender, name, color_idx])
	_rpc_lobby_update.rpc(Array(_peers), _names, _prefs)

# ── Broadcast lobby list to all clients ──────────────────────────────────────
@rpc("authority", "call_remote", "reliable")
func _rpc_lobby_update(peers: Array, names: Dictionary, color_idxs: Dictionary) -> void:
	pass   # stub — runs on clients only

# ── Tell all clients to start ─────────────────────────────────────────────────
# MUST match client's @rpc decorator exactly — Godot 4 hashes the config
@rpc("authority", "call_local", "reliable")
func _rpc_start_game(seed_val: int, asns: Dictionary, map_id: int) -> void:
	pass   # stub — runs on clients only

# ── Notify all clients that a peer left ──────────────────────────────────────
# MUST match client's @rpc decorator exactly
@rpc("authority", "call_local", "reliable")
func _rpc_peer_left(_pid: int) -> void:
	pass   # stub — runs on clients only

# ── Mid-game rejection RPC ────────────────────────────────────────────────────
# Server → late-connecting client: "the match is already running". The client
# shows a message and returns to the menu. Declared here (the server is the one
# that CALLS it) and as a receiver stub on the client. Godot 4 sends each RPC by
# its index in the node's alphabetically-sorted list of @rpc methods, so client
# and server MUST declare the IDENTICAL set of @rpc methods (matching decorators)
# or every index shifts and calls get misrouted/dropped.
@rpc("authority", "call_remote", "reliable")
func _rpc_game_in_progress() -> void:
	pass   # stub — runs on clients only

# ── Ping / pong ───────────────────────────────────────────────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_ping(timestamp_ms: int) -> void:
	_rpc_pong.rpc_id(multiplayer.get_remote_sender_id(), timestamp_ms)

# any_peer instead of authority: the WebSocket relay can echo this packet back
# through the server, which would otherwise fail the authority check
@rpc("any_peer", "call_remote", "reliable")
func _rpc_pong(_timestamp_ms: int) -> void:
	pass   # stub — runs on clients only

func _process(_delta: float) -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.poll()

# ── Public helper ─────────────────────────────────────────────────────────────
var player_names: Dictionary:
	get: return _names

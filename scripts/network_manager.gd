extends Node
class_name NetworkManager

signal lobby_ready(seed_val: int)
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

# Player identity info sent by each client at connect time
var _names: Dictionary = {}   # peer_id -> name string
var _prefs: Dictionary = {}   # peer_id -> preferred color index

func start_server() -> void:
	var peer = WebSocketMultiplayerPeer.new()
	# Bind to loopback only: the public wss:// endpoint is fronted by Caddy, which
	# proxies to this plain-ws backend. Nothing external should hit 9998 directly.
	var err = peer.create_server(PORT, "127.0.0.1")
	if err != OK:
		push_error("[Server] Failed to start on port %d (err %d)" % [PORT, err]); return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[Server] ws backend listening on 127.0.0.1:%d  (max %d players, TLS via Caddy)" % [PORT, Config.MAX_PLAYERS])

func _on_peer_connected(id: int) -> void:
	_peers.append(id)
	print("[Server] Peer %d joined  (%d/%d)" % [id, _peers.size(), Config.MAX_PLAYERS])
	_rpc_lobby_update.rpc(Array(_peers), _names, _prefs)

func _on_peer_disconnected(id: int) -> void:
	print("[Server] Peer %d disconnected" % id)
	_peers.erase(id)
	assignments.erase(id)
	_names.erase(id)
	_prefs.erase(id)
	_rpc_peer_left.rpc(id)
	_rpc_lobby_update.rpc(Array(_peers), _names, _prefs)
	peer_left.emit(id)

# ── Captain requests to start ─────────────────────────────────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_start() -> void:
	if not multiplayer.is_server(): return
	if _peers.size() < 1:
		print("[Server] No players connected, cannot start"); return
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

	print("[Server] Starting game — seed=%d  players=%s" % [s, str(assignments)])
	_rpc_start_game.rpc(s, assignments)
	lobby_ready.emit(s)

# ── Client sends name and color preference at connect time ────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_info(name: String, color_idx: int) -> void:
	var sender = multiplayer.get_remote_sender_id()
	_names[sender] = name
	_prefs[sender] = color_idx
	_rpc_lobby_update.rpc(Array(_peers), _names, _prefs)

# ── Broadcast lobby list to all clients ──────────────────────────────────────
@rpc("authority", "call_remote", "reliable")
func _rpc_lobby_update(peers: Array, names: Dictionary, color_idxs: Dictionary) -> void:
	pass   # stub — runs on clients only

# ── Tell all clients to start ─────────────────────────────────────────────────
# MUST match client's @rpc decorator exactly — Godot 4 hashes the config
@rpc("authority", "call_local", "reliable")
func _rpc_start_game(seed_val: int, asns: Dictionary) -> void:
	pass   # stub — runs on clients only

# ── Notify all clients that a peer left ──────────────────────────────────────
# MUST match client's @rpc decorator exactly
@rpc("authority", "call_local", "reliable")
func _rpc_peer_left(_pid: int) -> void:
	pass   # stub — runs on clients only

# ── Late-join RPC stubs ───────────────────────────────────────────────────────
# These run only on clients, but they MUST be declared here too. Godot 4 sends
# each RPC by its index in the node's alphabetically-sorted list of @rpc methods,
# so the client and server must declare the IDENTICAL set of @rpc methods (even
# as empty stubs) or every index shifts and calls get misrouted/dropped.
# Decorators must match the client's exactly.
@rpc("authority", "call_remote", "reliable")
func _rpc_late_join(_seed_val: int, _asns: Dictionary) -> void:
	pass   # stub — runs on clients only

@rpc("authority", "call_local", "reliable")
func _rpc_spawn_late_peer(_pid: int, _player_index: int) -> void:
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

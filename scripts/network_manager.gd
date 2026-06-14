extends Node
class_name NetworkManager

signal lobby_ready(seed_val: int)
signal peer_left(pid: int)

const PORT := 9999

# Ordered peer list — index = player_index
var _peers: Array = []

# Assignments: peer_id -> player_index (populated on start)
var assignments: Dictionary = {}

func start_server() -> void:
	var peer = WebSocketMultiplayerPeer.new()
	var err  = peer.create_server(PORT)
	if err != OK:
		push_error("[Server] Failed to start on port %d (err %d)" % [PORT, err]); return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[Server] WebSocket listening on port %d  (max %d players)" % [PORT, Config.MAX_PLAYERS])

func _on_peer_connected(id: int) -> void:
	_peers.append(id)
	print("[Server] Peer %d joined  (%d/%d)" % [id, _peers.size(), Config.MAX_PLAYERS])
	# Notify all existing clients about the updated lobby
	_rpc_lobby_update.rpc(Array(_peers))

func _on_peer_disconnected(id: int) -> void:
	print("[Server] Peer %d disconnected" % id)
	_peers.erase(id)
	assignments.erase(id)
	# Notify remaining clients so they remove the departed player from the game world
	_rpc_peer_left.rpc(id)
	# Also refresh lobby list in case the game hasn't started yet
	_rpc_lobby_update.rpc(Array(_peers))
	peer_left.emit(id)

# ── Captain requests to start ─────────────────────────────────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_start() -> void:
	if not multiplayer.is_server(): return
	if _peers.size() < 2:
		print("[Server] Need at least 2 players to start (have %d)" % _peers.size()); return
	_do_start()

func _do_start() -> void:
	var s = randi()
	assignments.clear()
	for i in _peers.size():
		assignments[_peers[i]] = i
	print("[Server] Starting game — seed=%d  players=%s" % [s, str(assignments)])
	_rpc_start_game.rpc(s, assignments)
	lobby_ready.emit(s)

# ── Broadcast lobby list to all clients ──────────────────────────────────────
@rpc("authority", "call_remote", "reliable")
func _rpc_lobby_update(peers: Array) -> void:
	pass   # stub — runs on clients only

# ── Tell all clients to start ─────────────────────────────────────────────────
@rpc("authority", "call_remote", "reliable")
func _rpc_start_game(seed_val: int, asns: Dictionary) -> void:
	pass   # stub — runs on clients only

# ── Notify all clients that a peer left ──────────────────────────────────────
@rpc("authority", "call_remote", "reliable")
func _rpc_peer_left(_pid: int) -> void:
	pass   # stub — runs on clients only

# ── Ping / pong ───────────────────────────────────────────────────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_ping(timestamp_ms: int) -> void:
	_rpc_pong.rpc_id(multiplayer.get_remote_sender_id(), timestamp_ms)

@rpc("authority", "call_remote", "reliable")
func _rpc_pong(_timestamp_ms: int) -> void:
	pass   # stub — runs on clients only

func _process(_delta: float) -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.poll()

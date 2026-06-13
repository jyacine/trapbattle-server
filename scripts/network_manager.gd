extends Node
class_name NetworkManager

signal lobby_ready(seed_val: int)
signal peer_left

const PORT := 9999

var _role_map: Dictionary = {}
var player_peer_id: int = 0
var robot_peer_id:  int = 0

func start_server() -> void:
	var peer = WebSocketMultiplayerPeer.new()
	var err  = peer.create_server(PORT)
	if err != OK:
		push_error("[Server] Failed to start on port %d (err %d)" % [PORT, err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[Server] WebSocket listening on port %d..." % PORT)

func _on_peer_connected(id: int) -> void:
	var roles = ["player", "robot"]
	_role_map[id] = roles[_role_map.size() % 2]
	print("[Server] Peer %d -> %s  (%d/2)" % [id, _role_map[id], _role_map.size()])
	if _role_map.size() < 2:
		return

	var p_id = -1; var r_id = -1
	for pid in _role_map:
		if _role_map[pid] == "player": p_id = pid
		else:                          r_id = pid
	player_peer_id = p_id
	robot_peer_id  = r_id

	var s = randi()
	print("[Server] Both connected — seed=%d  player=%d  robot=%d" % [s, p_id, r_id])
	_rpc_assign_role.rpc_id(p_id, "player", s, p_id, r_id)
	_rpc_assign_role.rpc_id(r_id, "robot",  s, p_id, r_id)
	lobby_ready.emit(s)

@rpc("authority", "call_remote", "reliable")
func _rpc_assign_role(_role: String, _seed_val: int, _p_peer: int, _r_peer: int) -> void:
	pass   # executed only on clients; stub keeps RPC table consistent

func _on_peer_disconnected(id: int) -> void:
	print("[Server] Peer %d disconnected" % id)
	peer_left.emit()

# WebSocketMultiplayerPeer must be polled manually every frame.
func _process(_delta: float) -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.poll()

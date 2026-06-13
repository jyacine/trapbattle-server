extends Node3D

var network_manager: NetworkManager
var game_manager: GameManager
var trap_manager: TrapManager
var _players: Dictionary = {}

func _ready() -> void:
	network_manager = NetworkManager.new()
	network_manager.name = "NetworkManager"
	add_child(network_manager)
	network_manager.lobby_ready.connect(_on_lobby_ready)
	network_manager.peer_left.connect(_on_peer_left)
	network_manager.start_server()

func _on_lobby_ready(seed_val: int) -> void:
	Config.maze_seed = seed_val

	game_manager = GameManager.new()
	game_manager.name = "GameManager"
	add_child(game_manager)

	trap_manager = TrapManager.new()
	trap_manager.name = "TrapManager"
	add_child(trap_manager)
	trap_manager.game_manager = game_manager

	for peer_id in network_manager._role_map:
		var role: String = network_manager._role_map[peer_id]
		var p = ServerPlayer.new()
		p.name   = "Player" if role == "player" else "Robot"
		p.role   = role
		p.game_manager = game_manager
		p.trap_manager = trap_manager
		p.set_multiplayer_authority(peer_id)
		add_child(p)
		_players[role] = p

	var p1 = _players.get("player") as ServerPlayer
	var p2 = _players.get("robot")  as ServerPlayer
	if p1 and p2:
		p1.robot_ref = p2
		p2.robot_ref = p1
		trap_manager.player = p1
		trap_manager.robot  = p2

	print("[Server] Game started  seed=%d" % seed_val)

func _on_peer_left() -> void:
	print("[Server] A player disconnected.")

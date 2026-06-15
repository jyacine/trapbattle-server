extends Node3D

var network_manager: NetworkManager
var game_manager: GameManager
var trap_manager: TrapManager
var voice_manager: VoiceManager
var _players: Dictionary = {}   # peer_id -> ServerPlayer

func _ready() -> void:
	network_manager = NetworkManager.new()
	network_manager.name = "NetworkManager"
	add_child(network_manager)
	network_manager.lobby_ready.connect(_on_lobby_ready)
	network_manager.peer_left.connect(_on_peer_left)
	network_manager.start_server()

	# VoiceManager must exist at "Main/VoiceManager" from game start so that
	# client voice RPCs sent before the game loads are routed correctly.
	voice_manager = VoiceManager.new()
	voice_manager.name = "VoiceManager"
	add_child(voice_manager)

func _on_lobby_ready(seed_val: int) -> void:
	Config.maze_seed = seed_val

	game_manager = GameManager.new()
	game_manager.name = "GameManager"
	add_child(game_manager)

	trap_manager = TrapManager.new()
	trap_manager.name = "TrapManager"
	add_child(trap_manager)
	trap_manager.game_manager = game_manager

	var assignments = network_manager.assignments   # {peer_id: player_index}
	for pid in assignments:
		var idx = assignments[pid]
		game_manager.register_player(pid)

		var p = ServerPlayer.new()
		p.name         = "Player_%d" % idx
		p.peer_id      = pid
		p.player_index = idx
		p.game_manager = game_manager
		p.trap_manager = trap_manager
		p.set_multiplayer_authority(pid)
		add_child(p)
		_players[pid] = p

	print("[Server] Game started — seed=%d  %d players" % [seed_val, _players.size()])

func _on_peer_left(pid: int) -> void:
	print("[Server] Player %d disconnected." % pid)
	if _players.has(pid):
		var node = _players[pid]
		if is_instance_valid(node):
			node.queue_free()
		_players.erase(pid)
	if game_manager and is_instance_valid(game_manager):
		game_manager.player_ids.erase(pid)
		game_manager.hp.erase(pid)
		game_manager.lives.erase(pid)
		game_manager.kills.erase(pid)
		game_manager.effects.erase(pid)
		game_manager.respawning.erase(pid)

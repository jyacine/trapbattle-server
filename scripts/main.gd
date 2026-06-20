extends Node3D

var network_manager: NetworkManager
var game_manager: GameManager
var trap_manager: TrapManager
var voice_manager: VoiceManager
var _players: Dictionary = {}   # peer_id -> ServerPlayer

func _ready() -> void:
	# Logger must be the very first child so every subsequent _ready() can use it.
	var logger := GameLogger.new()
	logger.name = "Logger"
	add_child(logger)

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

	GameLogger.info("Server ready — awaiting players")

func _on_lobby_ready(seed_val: int) -> void:
	Config.maze_seed = seed_val

	# The dedicated server is long-lived and hosts back-to-back matches. Tear down
	# the previous match BEFORE spawning the new one — otherwise the old
	# Player_<idx>/GameManager/TrapManager nodes linger, the new add_child() hits a
	# name collision and is auto-renamed, and the path /root/Main/Player_<idx> keeps
	# resolving to a STALE node owned by a peer from the previous game. That makes
	# the new owner's _net_pos RPCs fail the authority check (the log spam) and
	# freezes the server-side positions used for trap collision.
	_teardown_match()

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

	GameLogger.info("Game started — seed=%d  players=%d  assignments=%s" % [
		seed_val, _players.size(), str(assignments)])

# Free every node from the previous match. remove_child() detaches immediately so
# the node names ("GameManager", "Player_0", …) are free to reuse THIS frame;
# queue_free() then reclaims the memory safely next idle. (Plain queue_free alone
# keeps the node — and its name — in the tree until end of frame, so the freshly
# spawned same-named node would collide and the stale path would shadow it.)
func _teardown_match() -> void:
	for pid in _players:
		var node = _players[pid]
		if is_instance_valid(node):
			remove_child(node)
			node.queue_free()
	_players.clear()
	if game_manager and is_instance_valid(game_manager):
		remove_child(game_manager)
		game_manager.queue_free()
		game_manager = null
	if trap_manager and is_instance_valid(trap_manager):
		remove_child(trap_manager)
		trap_manager.queue_free()
		trap_manager = null

func _on_peer_left(pid: int) -> void:
	GameLogger.info("Cleaning up game state for peer %d" % pid)
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

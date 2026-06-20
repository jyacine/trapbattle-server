extends SceneTree

# Regression test for the multi-match authority bug.
# Before the fix, the long-lived dedicated server re-ran _on_lobby_ready without
# tearing down the previous match, so the SECOND game's add_child("Player_0")
# collided with the leftover node and got auto-renamed — leaving the path
# "Player_0" pointing at a STALE node owned by a peer from the FIRST game. That is
# what produced the "_net_pos is not allowed ... authority is <old peer>" spam.
#
# This test drives two matches with DIFFERENT peers at the same indices and
# asserts the named nodes resolve to the CURRENT owners (and that no stale
# Player_* duplicates linger). Authority is stored on the node even without a live
# multiplayer peer, so get_multiplayer_authority() is meaningful here.
#   Run: GODOT --headless --path <server> --script res://tests/teardown_check.gd

func _initialize() -> void:
	# GameLogger.info() (called inside _on_lobby_ready) needs an instance in-tree.
	var logger = GameLogger.new()
	logger.name = "Logger"
	get_root().add_child(logger)

	# Detached Main: _ready never fires (so it doesn't bind the real WS server),
	# but _on_lobby_ready can still build the match nodes under it.
	var main = load("res://scripts/main.gd").new()
	var nm = NetworkManager.new()
	main.network_manager = nm

	var ok := true

	# ── Match 1: peers 111 / 222 at indices 0 / 1 ─────────────────────────────
	nm.assignments = {111: 0, 222: 1}
	main._on_lobby_ready(1234)
	ok = _expect(main, "Player_0", 111) and ok
	ok = _expect(main, "Player_1", 222) and ok

	# ── Match 2: DIFFERENT peers 333 / 444 at the same indices ────────────────
	nm.assignments = {333: 0, 444: 1}
	main._on_lobby_ready(5678)
	ok = _expect(main, "Player_0", 333) and ok   # would be stale 111 without the fix
	ok = _expect(main, "Player_1", 444) and ok

	# No stale duplicate player nodes left behind.
	var player_nodes := 0
	for ch in main.get_children():
		if str(ch.name).begins_with("Player_"):
			player_nodes += 1
	if player_nodes != 2:
		push_error("expected 2 player nodes after match 2, found %d" % player_nodes)
		ok = false

	print("SERVER_TEARDOWN_CHECK %s  (player_nodes=%d)" % ["OK" if ok else "FAIL", player_nodes])
	quit(0 if ok else 1)

func _expect(main: Node, node_name: String, want_authority: int) -> bool:
	var n = main.get_node_or_null(node_name)
	if n == null:
		push_error("%s missing" % node_name)
		return false
	var got = n.get_multiplayer_authority()
	if got != want_authority:
		push_error("%s authority = %d, expected %d (stale node?)" % [node_name, got, want_authority])
		return false
	print("%s -> authority %d  OK" % [node_name, got])
	return true

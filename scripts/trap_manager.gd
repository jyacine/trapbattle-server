extends Node
class_name TrapManager

var game_manager: GameManager

# cell_str -> { "owner_pid": int, "type": int }
var _traps: Dictionary = {}

@rpc("any_peer", "call_local", "reliable")
func net_place_trap(cell: Array, owner_pid: int, trap_type: int) -> void:
	place_trap(cell, owner_pid, trap_type)

func place_trap(cell: Array, owner_pid: int, trap_type: int) -> void:
	_traps[str(cell)] = {"owner_pid": owner_pid, "type": trap_type}
	print("[Server] Trap type=%d at %s by peer %d" % [trap_type, str(cell), owner_pid])

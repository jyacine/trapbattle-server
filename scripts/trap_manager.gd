extends Node
class_name TrapManager

var game_manager: GameManager
var player: Node3D
var robot: Node3D

# cell key -> { "owner": str, "type": int }
var _traps: Dictionary = {}

@rpc("any_peer", "call_local", "reliable")
func net_place_trap(cell: Array, owner: String, trap_type: int) -> void:
	place_trap(cell, owner, trap_type)

func place_trap(cell: Array, owner: String, trap_type: int) -> void:
	_traps[str(cell)] = {"owner": owner, "type": trap_type}
	print("[Server] Trap type=%d at %s by %s" % [trap_type, str(cell), owner])

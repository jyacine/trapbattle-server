extends Node3D
class_name ServerPlayer

var role: String = "player"
var game_manager: GameManager
var trap_manager: Node
var robot_ref: Node3D

# Receive position broadcast from the authoritative client
@rpc("authority", "unreliable")
func _net_pos(pos: Vector3, y: float) -> void:
	if is_multiplayer_authority():
		return
	position  = pos
	rotation.y = y

func get_grid_position() -> Array:
	var cs = Config.CELL_SIZE
	return [int(position.x / cs), int(position.z / cs)]

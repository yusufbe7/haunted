extends Node3D
## Attached automatically to the spawned door_1 instance by hospital_generator.gd.
## Walk close and press E to swing the door open or closed.

@export var open_angle_deg: float = 90.0
@export var interact_distance: float = 2.5
@export var swing_speed: float = 3.0

var is_open := false
var target_rotation := 0.0
var _player: Node3D = null


func _ready() -> void:
	_ensure_interact_action()


func _ensure_interact_action() -> void:
	if not InputMap.has_action("interact"):
		InputMap.add_action("interact")
		var ev := InputEventKey.new()
		ev.keycode = KEY_E
		InputMap.action_add_event("interact", ev)


func _process(delta: float) -> void:
	if _player == null:
		_player = get_tree().get_root().find_child("Player", true, false)

	if _player and Input.is_action_just_pressed("interact"):
		if global_position.distance_to(_player.global_position) <= interact_distance:
			toggle()

	rotation_degrees.y = lerp(rotation_degrees.y, target_rotation, delta * swing_speed)


func toggle() -> void:
	is_open = not is_open
	target_rotation = open_angle_deg if is_open else 0.0

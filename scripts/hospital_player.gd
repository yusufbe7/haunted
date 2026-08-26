extends CharacterBody3D
## First-person controller for the CharacterBody3D that hospital_generator.gd
## spawns. WASD to move, mouse to look, Shift to run (loud!), F toggles the
## flashlight, Esc releases the mouse cursor.
##
## `noise_level` (0..1) is read by the monster: running is loud, walking is
## quiet, standing still is silent — so HOW you move decides if you're heard.

const WALK_SPEED := 3.2
const RUN_SPEED := 5.2
const MOUSE_SENSITIVITY := 0.0025
const GRAVITY := 9.8

var cam: Camera3D
var flashlight: SpotLight3D
var noise_level: float = 0.0      # 0 = silent, 1 = loud (running)


func _ready() -> void:
	add_to_group("player")
	cam = $PlayerCamera
	flashlight = get_node_or_null("PlayerCamera/Flashlight")
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_ensure_movement_actions()


func _ensure_movement_actions() -> void:
	var binds := {
		"move_forward": KEY_W,
		"move_back": KEY_S,
		"move_left": KEY_A,
		"move_right": KEY_D,
		"run": KEY_SHIFT,
		"flashlight": KEY_F,
	}
	for action in binds:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var ev := InputEventKey.new()
			ev.keycode = binds[action]
			InputMap.action_add_event(action, ev)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		cam.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		cam.rotation.x = clamp(cam.rotation.x, deg_to_rad(-80), deg_to_rad(80))
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event.is_action_pressed("flashlight") and flashlight != null:
		flashlight.visible = not flashlight.visible


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	var input_dir := Vector2.ZERO
	input_dir.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	input_dir.y = Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")
	input_dir = input_dir.normalized()

	var moving := input_dir.length() > 0.1
	var running := moving and Input.is_action_pressed("run")
	var speed := RUN_SPEED if running else WALK_SPEED

	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	move_and_slide()

	# How much noise am I making right now? (drives the monster's hearing)
	if running:
		noise_level = 1.0
	elif moving:
		noise_level = 0.4
	else:
		noise_level = 0.0

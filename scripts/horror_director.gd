extends Node
class_name HorrorDirector
## ============================================================================
##  HORROR DIRECTOR  — paces the scare so the monster is NOT shown up front.
## ============================================================================
##  Timeline (all configurable):
##    1. The room is calm; the monster is inactive and INVISIBLE.
##    2. After a while the ceiling lights flicker (something is wrong).
##    3. A brief, distant GLIMPSE: the monster appears for ~1s far away,
##       then vanishes — creepier than a jump-scare.
##    4. Lights flicker again, then the monster becomes ACTIVE and starts
##       hunting with its full AI.
##    5. If it catches the player -> screen fades to black -> GAME OVER.
##
##  The generator wires this up with setup(); nothing else is required.
## ============================================================================

@export var intro_duration: float = 22.0     # calm time before the hunt begins
@export var glimpse_at: float = 0.55          # fraction of intro when the glimpse happens
@export var enable_flicker: bool = true

var monster: MonsterAI = null
var player: Node3D = null
var lights: Array = []                         # OmniLight3D fixtures to flicker
var glimpse_point: Vector3 = Vector3.ZERO

var _base_energy: Array = []
var _fade: ColorRect = null
var _label: Label = null
var _fade_target: float = 0.0
var _fade_speed: float = 1.1
var _game_over: bool = false


func setup(p_monster: MonsterAI, p_player: Node3D, p_lights: Array, p_glimpse: Vector3) -> void:
	monster = p_monster
	player = p_player
	lights = p_lights
	glimpse_point = p_glimpse
	for l in lights:
		_base_energy.append(l.light_energy)
	if monster != null:
		monster.player_caught.connect(_on_player_caught)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # keep running even when the tree pauses
	_build_overlay()
	if monster != null:
		monster.active = false
		monster.visible = false
	_run_intro()


func _process(delta: float) -> void:
	if _fade != null:
		var col := _fade.color
		col.a = move_toward(col.a, _fade_target, _fade_speed * delta)
		_fade.color = col
		if _game_over and _label != null and col.a > 0.85 and not _label.visible:
			_label.visible = true


# =========================
#  INTRO TIMELINE
# =========================
func _run_intro() -> void:
	await get_tree().create_timer(intro_duration * glimpse_at).timeout
	if enable_flicker:
		await _flicker(1.2)

	# Brief distant glimpse.
	if monster != null:
		monster.global_position = glimpse_point
		monster.visible = true
		monster._play(monster.anim_idle)
		await get_tree().create_timer(1.2).timeout
		monster.visible = false

	await get_tree().create_timer(max(intro_duration * (1.0 - glimpse_at), 1.0)).timeout
	if enable_flicker:
		await _flicker(0.8)

	# The hunt begins.
	if monster != null:
		monster.visible = true
		monster.active = true


func _flicker(duration: float) -> void:
	if lights.is_empty():
		return
	var elapsed := 0.0
	while elapsed < duration:
		for i in range(lights.size()):
			var on := randf() > 0.45
			lights[i].light_energy = _base_energy[i] * (1.0 if on else 0.05)
		var step := randf_range(0.04, 0.12)
		await get_tree().create_timer(step).timeout
		elapsed += step
	for i in range(lights.size()):
		lights[i].light_energy = _base_energy[i]


# =========================
#  GAME OVER
# =========================
func _on_player_caught() -> void:
	if _game_over:
		return
	_game_over = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_fade_target = 1.0
	get_tree().paused = true   # freeze everything; the fade keeps going (ALWAYS)


# =========================
#  OVERLAY (fade + GAME OVER text)
# =========================
func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)

	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_fade)

	_label = Label.new()
	_label.text = "GAME OVER"
	_label.visible = false
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.add_theme_font_size_override("font_size", 64)
	_label.add_theme_color_override("font_color", Color(0.75, 0.05, 0.05))
	layer.add_child(_label)

extends CharacterBody3D
class_name MonsterAI
## ============================================================================
##  MONSTER AI  — 6-state horror stalker  (Godot 4.7.1)
## ============================================================================
##  IDLE   -> stands still, hidden. The Horror Director enables it later.
##  PATROL -> walks between patrol points around the level.
##  HEAR   -> heard the player (running / noise); turns toward the sound.
##  SEARCH -> goes to the player's last known position and looks around.
##  CHASE  -> can see the player: runs at them.
##  ATTACK -> reached the player: emits `player_caught` (Director => Game Over).
##
##  Works WITH or WITHOUT a real model:
##    * attach this to a CharacterBody3D that has the monster mesh as a child;
##    * if the mesh has an AnimationPlayer, animations play automatically
##      (set the four anim name exports to match your model);
##    * if there is no model at all, the generator gives it a placeholder mesh
##      so the whole AI is still visible and testable.
## ============================================================================

enum State { IDLE, PATROL, HEAR, SEARCH, CHASE, ATTACK }

signal player_caught          # ATTACK reached the player -> Director fades out
signal state_changed(new_state: int)

@export_group("Speeds (m/s)")
@export var patrol_speed: float = 1.6
@export var search_speed: float = 2.4
@export var chase_speed: float = 3.8
@export var turn_speed: float = 7.0
@export var gravity: float = 12.0

@export_group("Senses")
@export var view_distance: float = 16.0
@export var view_angle_deg: float = 55.0     # half-angle of the vision cone
@export var eye_height: float = 1.6
@export var hearing_radius: float = 11.0     # scaled by the player's noise level
@export var attack_range: float = 1.7
@export var lose_sight_time: float = 4.0     # keep chasing this long after LOS lost
@export var search_look_time: float = 7.0    # how long to search before giving up

@export_group("Animation names (match your model, or leave defaults)")
@export var anim_idle: String = "Idle"
@export var anim_walk: String = "Walk"
@export var anim_run: String = "Run"
@export var anim_attack: String = "Attack"

@export_group("Behavior")
## The Director flips this on after the intro so the monster starts hunting.
@export var active: bool = false
@export var patrol_points: Array[Vector3] = []

var state: int = State.IDLE
var player: Node3D = null
var anim: AnimationPlayer = null

var _last_known_pos: Vector3 = Vector3.ZERO
var _patrol_index: int = 0
var _lost_timer: float = 0.0
var _search_timer: float = 0.0
var _caught: bool = false
var _current_anim: String = ""


func _ready() -> void:
	add_to_group("monster")
	anim = _find_anim_player(self)
	_set_state(State.IDLE)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta

	if player == null:
		var found := get_tree().get_first_node_in_group("player")
		if found == null:
			found = get_tree().get_root().find_child("Player", true, false)
		if found is Node3D:
			player = found

	if not active or _caught:
		velocity.x = 0.0
		velocity.z = 0.0
		_play(anim_idle)
		move_and_slide()
		return

	_update_state(delta)
	move_and_slide()


# =========================
#  STATE MACHINE
# =========================
func _update_state(delta: float) -> void:
	var sees := can_see_player()
	if sees and player != null:
		_last_known_pos = player.global_position

	match state:
		State.IDLE:
			_set_state(State.PATROL)

		State.PATROL:
			if sees:
				_set_state(State.CHASE)
			elif _hears_player():
				_last_known_pos = player.global_position
				_set_state(State.HEAR)
			else:
				_do_patrol()

		State.HEAR:
			_face_point(_last_known_pos, delta)
			_stop_moving()
			_search_timer += delta
			if sees:
				_set_state(State.CHASE)
			elif _search_timer > 1.2:
				_set_state(State.SEARCH)

		State.SEARCH:
			if sees:
				_set_state(State.CHASE)
				return
			_search_timer += delta
			if _hears_player():
				_last_known_pos = player.global_position
				_search_timer = 0.0
			_move_toward(_last_known_pos, search_speed, delta)
			if global_position.distance_to(_last_known_pos) < 1.2 or _search_timer > search_look_time:
				_set_state(State.PATROL)

		State.CHASE:
			if player == null:
				_set_state(State.SEARCH)
				return
			_move_toward(player.global_position, chase_speed, delta)
			if global_position.distance_to(player.global_position) <= attack_range:
				_set_state(State.ATTACK)
			elif not sees:
				_lost_timer += delta
				if _lost_timer > lose_sight_time:
					_set_state(State.SEARCH)
			else:
				_lost_timer = 0.0

		State.ATTACK:
			_stop_moving()
			if not _caught:
				_caught = true
				_play(anim_attack)
				emit_signal("player_caught")


func _set_state(new_state: int) -> void:
	if state == new_state:
		return
	state = new_state
	_lost_timer = 0.0
	_search_timer = 0.0
	emit_signal("state_changed", new_state)
	match new_state:
		State.IDLE:      _play(anim_idle)
		State.PATROL:    _play(anim_walk)
		State.HEAR:      _play(anim_idle)
		State.SEARCH:    _play(anim_walk)
		State.CHASE:     _play(anim_run)
		State.ATTACK:    _play(anim_attack)


# =========================
#  MOVEMENT
# =========================
func _do_patrol() -> void:
	if patrol_points.is_empty():
		_stop_moving()
		return
	var target: Vector3 = patrol_points[_patrol_index]
	_move_toward(target, patrol_speed, get_physics_process_delta_time())
	if global_position.distance_to(target) < 1.2:
		_patrol_index = (_patrol_index + 1) % patrol_points.size()


func _move_toward(target: Vector3, speed: float, delta: float) -> void:
	var to := target - global_position
	to.y = 0.0
	if to.length() < 0.05:
		_stop_moving()
		return
	var dir := to.normalized()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	_face_point(target, delta)


func _stop_moving() -> void:
	velocity.x = 0.0
	velocity.z = 0.0


func _face_point(target: Vector3, delta: float) -> void:
	var to := target - global_position
	to.y = 0.0
	if to.length() < 0.05:
		return
	var desired := atan2(to.x, to.z)          # face +Z toward target
	rotation.y = lerp_angle(rotation.y, desired, clamp(turn_speed * delta, 0.0, 1.0))


# =========================
#  PERCEPTION
# =========================
func can_see_player() -> bool:
	if player == null:
		return false
	var to_player: Vector3 = player.global_position - global_position
	var dist := to_player.length()
	if dist > view_distance:
		return false

	var forward := -global_transform.basis.z
	forward.y = 0.0
	var flat := Vector3(to_player.x, 0.0, to_player.z)
	if forward.length() > 0.01 and flat.length() > 0.01:
		var ang := rad_to_deg(forward.normalized().angle_to(flat.normalized()))
		if ang > view_angle_deg:
			return false

	# Line of sight: is anything solid between the monster's eye and the player?
	var from := global_position + Vector3(0, eye_height, 0)
	var to := player.global_position + Vector3(0, 1.2, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return true
	var col = hit.get("collider")
	return col == player or (col is Node and player.is_ancestor_of(col))


func _hears_player() -> bool:
	if player == null:
		return false
	var raw = player.get("noise_level")     # dynamic: player may not define it
	if raw == null:
		return false
	var noise := float(raw)
	if noise <= 0.01:
		return false
	return global_position.distance_to(player.global_position) <= hearing_radius * noise


# =========================
#  ANIMATION HELPERS
# =========================
func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var found := _find_anim_player(c)
		if found:
			return found
	return null


func _play(anim_name: String) -> void:
	if anim == null or anim_name == "" or _current_anim == anim_name:
		return
	# Try the given name, then a lowercase variant, so odd exports still animate.
	var candidates := [anim_name, anim_name.to_lower(), anim_name.capitalize()]
	for c in candidates:
		if anim.has_animation(c):
			anim.play(c)
			_current_anim = anim_name
			return

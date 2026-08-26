extends Node3D
## ============================================================================
##  HAUNTED SALVAGE — HOSPITAL FLOOR 1 GENERATOR  (Godot 4.7.1)
## ============================================================================
##  Builds a whole first floor at runtime from your FBX kit:
##
##        NORTH (+Z)
##     +---------------------+
##     | P1 |         | P4 |
##     |----|         |----|
##     | P2 | CORRIDOR| P5 |
##     |----|         |----|
##     | P3 |         | P6 |
##     +----+---------+----+
##     |  NURSE  |  RECEPTION |
##     +---------+------------+
##     | STORAGE |STAIRS| ENTRANCE(door) |
##     +---------------------+   SOUTH (-Z)
##
##   * 6 wards, each furnished (bed, bedside table, chair, cabinet, IV stand,
##     ceiling light, trash bin, wall poster)
##   * central corridor with a row of lights (some broken / flickering)
##   * nurse station, reception, storage, stairs, entrance
##   * floor tiled from floor_tile_1.fbx, PBR ceiling from the Ceiling_1 set,
##     PBR bed from the Bed_ set
##   * first-person player (WASD, run=Shift, flashlight=F) + the monster system
##
##   A missing FBX/texture prints "MODEL TOPILMADI: ..." and building continues.
## ============================================================================

# =========================
#  LAYOUT  (meters — tweak in the Inspector)
# =========================
@export_group("Building layout")
@export var ward_w: float = 6.0          # each ward width (along X)
@export var ward_l: float = 5.0          # each ward depth (along Z)
@export var corridor_w: float = 4.0
@export var band_l: float = 5.0          # nurse/reception band depth
@export var bottom_l: float = 5.0        # storage/stairs/entrance band depth
@export var room_height: float = 4.0
@export var wall_thickness: float = 0.2
@export var door_gap: float = 2.0        # ward doorway width
@export var entrance_gap: float = 2.8    # main entrance width

@export_group("Assets")
@export var models_path: String = "res://models/"
@export var scripts_path: String = "res://scripts/"
@export var bed_texture_dir: String = "res://models/textures/bed/"
@export var ceiling_texture_dir: String = "res://models/textures/ceiling/"

@export_group("Monster")
@export var enable_monster: bool = true
@export var monster_dir: String = "res://assets/monster/"
@export var monster_file: String = "monster"
@export var monster_scale: float = 1.0
@export var monster_intro_seconds: float = 22.0

@export_group("Debug")
@export var debug_top_down: bool = false

const FALLBACK_MODEL_DIRS := ["res://models/", "res://assets/hospital_kit/"]
const NAME_ALIASES := {
	"Magazine_1": ["Magazine_1", "Magazine1"],
	"floor_tile_1": ["floor_tile_1", "floor_tile"],
	"ceiling_light": ["ceiling_light", "CeilingLight"],
}

var _models: Dictionary = {}
var _bed_material: StandardMaterial3D = null
var _ceiling_material: StandardMaterial3D = null
var _ceiling_lamps: Array = []
var _player: Node3D = null

# Building bounds, filled by build_floor_plan().
var b_xmin: float = 0.0
var b_xmax: float = 0.0
var b_zmin: float = 0.0
var b_zmax: float = 0.0
var entrance_x: float = 0.0


# =========================
#  ENTRY POINT
# =========================
func _ready() -> void:
	_ensure_input_actions()
	create_lighting()
	build_floor_plan()
	if debug_top_down:
		create_debug_camera()
	else:
		create_camera()
		if enable_monster:
			spawn_monster_system()
	print("Hospital floor ready: %.1fm x %.1fm" % [b_xmax - b_xmin, b_zmax - b_zmin])


func _ensure_input_actions() -> void:
	var binds := {
		"move_forward": KEY_W, "move_back": KEY_S,
		"move_left": KEY_A, "move_right": KEY_D,
		"interact": KEY_E, "run": KEY_SHIFT, "flashlight": KEY_F,
	}
	for action in binds:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var ev := InputEventKey.new()
		ev.keycode = binds[action]
		InputMap.action_add_event(action, ev)


# =========================
#  ASSET LOADING
# =========================
func get_model(base_name: String) -> PackedScene:
	if _models.has(base_name):
		return _models[base_name]
	var names: Array = NAME_ALIASES.get(base_name, [base_name])
	var dirs: Array = [models_path]
	for d in FALLBACK_MODEL_DIRS:
		if not dirs.has(d):
			dirs.append(d)
	for dir in dirs:
		for nm in names:
			var path: String = dir.path_join(nm + ".fbx")
			if ResourceLoader.exists(path):
				var res: PackedScene = load(path)
				_models[base_name] = res
				return res
	push_warning("MODEL TOPILMADI: %s.fbx" % base_name)
	print("MODEL TOPILMADI: %s.fbx" % base_name)
	_models[base_name] = null
	return null


func spawn_model(base_name: String, rot_y_deg: float = 0.0, parent: Node3D = self) -> Node3D:
	var packed := get_model(base_name)
	if packed == null:
		return null
	var inst: Node3D = packed.instantiate()
	parent.add_child(inst)
	inst.rotation_degrees.y = rot_y_deg
	fix_culling(inst)
	return inst


func fix_culling(node: Node) -> void:
	if node is MeshInstance3D and node.mesh:
		for i in range(node.mesh.get_surface_count()):
			var mat := node.get_active_material(i)
			if mat and mat is BaseMaterial3D:
				mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for child in node.get_children():
		fix_culling(child)


# =========================
#  AABB HELPERS
# =========================
func get_world_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var initialized := false
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and n.mesh:
			var box: AABB = (n as MeshInstance3D).mesh.get_aabb()
			var world_box: AABB = (n as MeshInstance3D).global_transform * box
			if not initialized:
				result = world_box
				initialized = true
			else:
				result = result.merge(world_box)
		for c in n.get_children():
			if c is Node3D:
				stack.append(c)
	return result


func seat_on_floor(inst: Node3D, x: float, z: float, bottom_y: float = 0.0) -> void:
	if inst == null:
		return
	var box := get_world_aabb(inst)
	var center := box.position + box.size * 0.5
	inst.global_position += Vector3(x - center.x, bottom_y - box.position.y, z - center.z)


func hang_from(inst: Node3D, x: float, z: float, top_y: float) -> void:
	if inst == null:
		return
	var box := get_world_aabb(inst)
	var center := box.position + box.size * 0.5
	inst.global_position += Vector3(x - center.x, top_y - (box.position.y + box.size.y), z - center.z)


func center_at(inst: Node3D, target: Vector3) -> void:
	if inst == null:
		return
	var box := get_world_aabb(inst)
	var center := box.position + box.size * 0.5
	inst.global_position += target - center


func top_y_of(inst: Node3D) -> float:
	if inst == null:
		return 0.0
	var box := get_world_aabb(inst)
	return box.position.y + box.size.y


# =========================
#  BOX BUILDER
# =========================
func create_box(size: Vector3, pos: Vector3, mat: Material, with_collision: bool = true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	if with_collision:
		var body := StaticBody3D.new()
		mi.add_child(body)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		shape.shape = box
		body.add_child(shape)
	return mi


func solid_color_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.92
	mat.metallic = 0.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


# =========================
#  FLOOR PLAN — top level
# =========================
func build_floor_plan() -> void:
	# --- derive coordinates ---
	var corr_half := corridor_w / 2.0
	b_xmin = -(corr_half + ward_w)
	b_xmax = corr_half + ward_w
	var wards_l := 3.0 * ward_l
	b_zmax = (wards_l + band_l + bottom_l) / 2.0
	b_zmin = -b_zmax

	var xL0 := b_xmin           # left column outer wall
	var xL1 := -corr_half       # left column inner wall (corridor side)
	var xR0 := corr_half        # right column inner wall
	var xR1 := b_xmax           # right column outer wall

	# Ward row Z spans, north -> south.
	var rowZ := []
	var z := b_zmax
	for i in range(3):
		rowZ.append([z - ward_l, z])   # [zmin, zmax]
		z -= ward_l
	var band_z := [z - band_l, z]       # nurse / reception
	z -= band_l
	var bottom_z := [z - bottom_l, z]   # storage / stairs / entrance

	entrance_x = (corr_half + xR1) / 2.0   # centre of the entrance third (right)

	build_floor()
	build_ceiling()

	# --- outer perimeter (single entrance gap on south wall) ---
	build_wall_x(b_zmax, b_xmin, b_xmax, [])                       # north
	build_wall_z(b_xmin, b_zmin, b_zmax, [])                       # west
	build_wall_z(b_xmax, b_zmin, b_zmax, [])                       # east
	build_wall_x(b_zmin, b_xmin, b_xmax, [[entrance_x, entrance_gap]])  # south (door)

	# --- corridor side walls (one door per ward) ---
	var left_gaps := []
	var right_gaps := []
	for r in rowZ:
		var cz: float = (r[0] + r[1]) / 2.0
		left_gaps.append([cz, door_gap])
		right_gaps.append([cz, door_gap])
	build_wall_z(xL1, rowZ[2][0], b_zmax, left_gaps)   # left inner wall
	build_wall_z(xR0, rowZ[2][0], b_zmax, right_gaps)  # right inner wall

	# --- horizontal walls between stacked wards ---
	for i in range(1, 3):
		var zc: float = rowZ[i][1]   # boundary between row i-1 and row i
		build_wall_x(zc, xL0, xL1, [])
		build_wall_x(zc, xR0, xR1, [])

	# --- ward outer end caps already covered by perimeter (west/east) ---

	# --- band + lobby dividing walls (central corridor lane stays open) ---
	var band_cz: float = (band_z[0] + band_z[1]) / 2.0
	var bcz: float = (bottom_z[0] + bottom_z[1]) / 2.0
	# wall between ward row3 and the band, open at the corridor
	build_wall_x(band_z[1], b_xmin, b_xmax, [[0.0, corridor_w]])
	# wall between the band and the entrance lobby, open at the corridor
	build_wall_x(bottom_z[1], b_xmin, b_xmax, [[0.0, corridor_w]])

	# --- furniture & doors & lights per room ---
	var wards := [
		[xL0, xL1, rowZ[0][0], rowZ[0][1], -1.0],  # P1 (outer=west)
		[xL0, xL1, rowZ[1][0], rowZ[1][1], -1.0],  # P2
		[xL0, xL1, rowZ[2][0], rowZ[2][1], -1.0],  # P3
		[xR0, xR1, rowZ[0][0], rowZ[0][1],  1.0],  # P4 (outer=east)
		[xR0, xR1, rowZ[1][0], rowZ[1][1],  1.0],  # P5
		[xR0, xR1, rowZ[2][0], rowZ[2][1],  1.0],  # P6
	]
	var idx := 0
	for w in wards:
		furnish_ward(w[0], w[1], w[2], w[3], w[4])
		# door into the corridor (inner wall = corridor side)
		var cz: float = (w[2] + w[3]) / 2.0
		var door_x: float = w[1] if w[4] < 0.0 else w[0]
		place_door_at(Vector3(door_x, 0.0, cz), true)
		# ward ceiling light (P3 & P6 flicker for mood)
		var flicker := idx == 2 or idx == 5
		add_room_light((w[0] + w[1]) / 2.0, cz, flicker)
		idx += 1

	var corr_half2 := corridor_w / 2.0
	# nurse (left of corridor) / reception (right of corridor)
	furnish_nurse(b_xmin, -corr_half2, band_z[0], band_z[1])
	furnish_reception(corr_half2, b_xmax, band_z[0], band_z[1])
	add_room_light((b_xmin - corr_half2) / 2.0, band_cz, false)
	add_room_light((b_xmax + corr_half2) / 2.0, band_cz, false)

	# storage (left) / entrance lobby (right)
	furnish_storage(b_xmin, -corr_half2, bottom_z[0], bottom_z[1])
	furnish_entrance(corr_half2, b_xmax, bottom_z[0], bottom_z[1])
	add_room_light((b_xmin - corr_half2) / 2.0, bcz, true)   # storage flickers
	add_room_light(entrance_x, bcz, false)

	# main entrance door + exit sign (south wall runs along X -> faces_x = false)
	place_door_at(Vector3(entrance_x, 0.0, b_zmin), false, entrance_gap)
	var sign := spawn_model("Exit_sign")
	if sign != null:
		center_at(sign, Vector3(entrance_x, 2.6, b_zmin + 0.2))

	# corridor lights (a row down the middle; every other one is broken)
	build_corridor_lights(rowZ[2][0], b_zmax)


# =========================
#  FLOOR & CEILING
# =========================
func build_floor() -> void:
	# collision slab
	var body := StaticBody3D.new()
	body.name = "FloorCollision"
	add_child(body)
	var shp := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = Vector3(b_xmax - b_xmin, 0.2, b_zmax - b_zmin)
	shp.shape = bx
	shp.position = Vector3((b_xmin + b_xmax) / 2.0, -0.1, (b_zmin + b_zmax) / 2.0)
	body.add_child(shp)

	var sample := spawn_model("floor_tile_1")
	if sample == null:
		create_box(Vector3(b_xmax - b_xmin, 0.05, b_zmax - b_zmin),
			Vector3((b_xmin + b_xmax) / 2.0, -0.025, (b_zmin + b_zmax) / 2.0),
			solid_color_material(Color(0.85, 0.86, 0.88)), false)
		return
	var tile := get_world_aabb(sample)
	var step_x: float = max(tile.size.x, 0.5)
	var step_z: float = max(tile.size.z, 0.5)
	sample.queue_free()

	var cols: int = int(ceil((b_xmax - b_xmin) / step_x))
	var rows: int = int(ceil((b_zmax - b_zmin) / step_z))
	for c in range(cols):
		for r in range(rows):
			var t := spawn_model("floor_tile_1")
			if t == null:
				continue
			seat_on_floor(t, b_xmin + (c + 0.5) * step_x, b_zmin + (r + 0.5) * step_z, 0.0)


func build_ceiling() -> void:
	create_box(
		Vector3(b_xmax - b_xmin, wall_thickness, b_zmax - b_zmin),
		Vector3((b_xmin + b_xmax) / 2.0, room_height + wall_thickness / 2.0, (b_zmin + b_zmax) / 2.0),
		_get_ceiling_material(),
		false)


# =========================
#  WALL BUILDERS
# =========================
## Solid spans along one axis from a1..a2, given [center,width] gaps.
func _solid_spans(a1: float, a2: float, gaps: Array) -> Array:
	var sorted := gaps.duplicate()
	sorted.sort_custom(func(x, y): return x[0] < y[0])
	var spans := []
	var cursor := a1
	for g in sorted:
		var gs: float = g[0] - g[1] / 2.0
		var ge: float = g[0] + g[1] / 2.0
		if gs > cursor:
			spans.append([cursor, gs])
		cursor = max(cursor, ge)
	if cursor < a2 - 0.001:
		spans.append([cursor, a2])
	return spans


func _wall_material() -> StandardMaterial3D:
	return solid_color_material(Color(0.92, 0.93, 0.94))


## Wall running along X at fixed z.
func build_wall_x(z: float, x1: float, x2: float, gaps: Array) -> void:
	for s in _solid_spans(x1, x2, gaps):
		var length: float = s[1] - s[0]
		if length < 0.01:
			continue
		create_box(Vector3(length, room_height, wall_thickness),
			Vector3((s[0] + s[1]) / 2.0, room_height / 2.0, z), _wall_material())


## Wall running along Z at fixed x.
func build_wall_z(x: float, z1: float, z2: float, gaps: Array) -> void:
	for s in _solid_spans(z1, z2, gaps):
		var length: float = s[1] - s[0]
		if length < 0.01:
			continue
		create_box(Vector3(wall_thickness, room_height, length),
			Vector3(x, room_height / 2.0, (s[0] + s[1]) / 2.0), _wall_material())


func place_door_at(opening: Vector3, faces_x: bool, width: float = 0.0) -> void:
	var packed := get_model("door_1")
	if packed == null:
		return
	var door: Node3D = packed.instantiate()
	var door_script_path := scripts_path.path_join("hospital_door.gd")
	if ResourceLoader.exists(door_script_path):
		door.set_script(load(door_script_path))
	add_child(door)
	if faces_x:
		door.rotation_degrees.y = 90.0
	fix_culling(door)
	seat_on_floor(door, opening.x, opening.z, 0.0)


# =========================
#  WARD FURNITURE
# =========================
## outer_dir: -1 => outer wall is on -X (left column), +1 => +X (right column).
func furnish_ward(xmin: float, xmax: float, zmin: float, zmax: float, outer_dir: float) -> void:
	var cz := (zmin + zmax) / 2.0
	var outer_x := xmin if outer_dir < 0.0 else xmax
	var inner_x := xmax if outer_dir < 0.0 else xmin
	var into := -outer_dir   # direction from outer wall toward the room interior

	# Bed against the outer wall.
	var bed_x := outer_x + into * 1.6
	var bed := spawn_model("bed", 90.0 if outer_dir < 0.0 else 270.0)
	seat_on_floor(bed, bed_x, cz)
	apply_bed_material(bed)

	# Bedside table (small cabinet) at the head of the bed.
	seat_on_floor(spawn_model("cabinet_3", 0.0), bed_x, cz - 1.7)

	# IV stand + bag at the other side of the head.
	var iv_holder := spawn_model("IV_Bag_holder")
	seat_on_floor(iv_holder, bed_x, cz + 1.6)
	hang_from(spawn_model("IV_Bag"), bed_x, cz + 1.6, top_y_of(iv_holder) - 0.1)

	# Chair toward the corridor side.
	seat_on_floor(spawn_model("chair", 90.0 if outer_dir > 0.0 else 270.0),
		inner_x - into * 1.4, cz + 0.6)

	# Cabinet against the north wall of the room.
	seat_on_floor(spawn_model("cabinet_1", 180.0), (xmin + xmax) / 2.0, zmax - 0.6)

	# Trash bin (no model in the kit -> small dark box).
	create_box(Vector3(0.35, 0.5, 0.35), Vector3(inner_x - into * 0.5, 0.25, zmin + 0.5),
		solid_color_material(Color(0.12, 0.13, 0.14)), false)

	# Wall poster on the outer wall, above the bed.
	var poster_col := Color(0.75, 0.78, 0.7) if randf() > 0.5 else Color(0.6, 0.7, 0.78)
	create_box(Vector3(0.05, 0.8, 1.1),
		Vector3(outer_x + into * (wall_thickness / 2.0 + 0.03), 2.3, cz),
		solid_color_material(poster_col), false)


func furnish_nurse(xmin: float, xmax: float, zmin: float, zmax: float) -> void:
	var cx := (xmin + xmax) / 2.0
	var cz := (zmin + zmax) / 2.0
	var table := spawn_model("table", 0.0)
	seat_on_floor(table, cx, cz)
	seat_on_floor(spawn_model("chair", 0.0), cx, cz + 1.2)
	seat_on_floor(spawn_model("cabinet_1", 90.0), xmin + 0.6, cz)
	seat_on_floor(spawn_model("cabinet_2", 90.0), xmin + 0.6, cz - 2.0)
	# Magazine on the table top.
	seat_on_floor(spawn_model("Magazine_1", 15.0), cx, cz, top_y_of(table))


func furnish_reception(xmin: float, xmax: float, zmin: float, zmax: float) -> void:
	var cx := (xmin + xmax) / 2.0
	var cz := (zmin + zmax) / 2.0
	seat_on_floor(spawn_model("bench", 0.0), cx, zmax - 0.9)
	seat_on_floor(spawn_model("bench", 0.0), cx + 2.5, zmax - 0.9)
	seat_on_floor(spawn_model("cabinet_1", -90.0), xmax - 0.6, cz)


func furnish_storage(xmin: float, xmax: float, zmin: float, zmax: float) -> void:
	seat_on_floor(spawn_model("cabinet_1", 90.0), xmin + 0.6, zmax - 1.5)
	seat_on_floor(spawn_model("cabinet_2", 90.0), xmin + 0.6, zmax - 3.0)
	seat_on_floor(spawn_model("cabinet_3", 0.0), xmax - 1.0, zmin + 1.0)


func furnish_entrance(xmin: float, xmax: float, zmin: float, zmax: float) -> void:
	var cx := (xmin + xmax) / 2.0
	seat_on_floor(spawn_model("bench", 90.0), xmin + 0.7, (zmin + zmax) / 2.0)


# =========================
#  LIGHTS
# =========================
func add_room_light(x: float, z: float, broken: bool, cast_shadow: bool = true) -> void:
	var fixture := spawn_model("ceiling_light")
	if fixture != null:
		hang_from(fixture, x, z, room_height - 0.02)
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(x, room_height - 0.4, z)
	lamp.light_color = Color(1.0, 0.98, 0.94)
	lamp.omni_range = max(ward_w, ward_l) * 1.6
	lamp.omni_attenuation = 1.3
	lamp.shadow_enabled = cast_shadow and not broken
	if broken:
		lamp.light_energy = 1.6
		var fl_path := scripts_path.path_join("flicker_light.gd")
		if ResourceLoader.exists(fl_path):
			lamp.set_script(load(fl_path))
	else:
		lamp.light_energy = 1.7
	add_child(lamp)
	_ceiling_lamps.append(lamp)


func build_corridor_lights(z_south: float, z_north: float) -> void:
	var count: int = max(2, int((z_north - z_south) / 4.0))
	for i in range(count + 1):
		var z: float = lerp(z_south + 1.0, z_north - 1.0, float(i) / float(count))
		# Corridor lights don't cast shadows (keeps the shadow-map count sane).
		add_room_light(0.0, z, i % 3 == 1, false)


# =========================
#  PBR MATERIALS (bed + ceiling)
# =========================
func apply_bed_material(bed: Node3D) -> void:
	if bed == null:
		return
	var mat := _get_bed_material()
	if mat != null:
		_apply_material_recursive(bed, mat)


func _get_bed_material() -> StandardMaterial3D:
	if _bed_material != null:
		return _bed_material
	_bed_material = _make_pbr("Bed", [bed_texture_dir, "res://assets/hospital_kit/textures/bed/"], 1.0)
	if _bed_material == null:
		print("MODEL TOPILMADI: Bed_BaseColor.png (bed keeps default material)")
	return _bed_material


func _get_ceiling_material() -> StandardMaterial3D:
	if _ceiling_material != null:
		return _ceiling_material
	var m := _make_pbr("Ceiling_1", [ceiling_texture_dir, "res://assets/hospital_kit/textures/ceiling/"],
		max(1.0, (b_xmax - b_xmin) / 2.0))
	if m == null:
		print("MODEL TOPILMADI: Ceiling_1_BaseColor.png (using plain white ceiling)")
		m = solid_color_material(Color(0.97, 0.97, 0.97))
	_ceiling_material = m
	return m


## Build a StandardMaterial3D from a <prefix>_BaseColor/Metallic/Roughness/Normal
## texture set found in one of `dirs`. uv_tiles repeats the texture.
func _make_pbr(prefix: String, dirs: Array, uv_tiles: float) -> StandardMaterial3D:
	var base := _load_tex(prefix + "_BaseColor", dirs)
	if base == null:
		return null
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = base
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if uv_tiles > 1.0:
		mat.uv1_scale = Vector3(uv_tiles, uv_tiles, 1.0)
	var metal := _load_tex(prefix + "_Metallic", dirs)
	if metal != null:
		mat.metallic = 1.0
		mat.metallic_texture = metal
	var rough := _load_tex(prefix + "_Roughness", dirs)
	if rough != null:
		mat.roughness = 1.0
		mat.roughness_texture = rough
	var normal := _load_tex(prefix + "_Normal", dirs)
	if normal != null:
		mat.normal_enabled = true
		mat.normal_texture = normal
	return mat


func _load_tex(base_name: String, dirs: Array) -> Texture2D:
	for dir in dirs:
		var path: String = dir.path_join(base_name + ".png")
		if ResourceLoader.exists(path):
			return load(path)
	return null


func _apply_material_recursive(node: Node, mat: Material) -> void:
	if node is MeshInstance3D and node.mesh:
		for i in range((node as MeshInstance3D).mesh.get_surface_count()):
			(node as MeshInstance3D).set_surface_override_material(i, mat)
	for child in node.get_children():
		_apply_material_recursive(child, mat)


# =========================
#  LIGHTING ENVIRONMENT
# =========================
func create_lighting() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "SunLight"
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 0.5      # mostly blocked by the ceiling; ceiling lamps do the work
	sun.shadow_enabled = true
	add_child(sun)

	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.06)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.47, 0.5)
	env.ambient_light_energy = 0.45   # dim + moody, but you can still see
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.environment = env
	add_child(world)


# =========================
#  CAMERA / PLAYER
# =========================
func create_camera() -> void:
	var player := CharacterBody3D.new()
	player.name = "Player"
	var collider := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.7
	capsule.radius = 0.35
	collider.shape = capsule
	collider.position.y = 0.85
	player.add_child(collider)

	var cam := Camera3D.new()
	cam.name = "PlayerCamera"
	cam.position = Vector3(0, 1.7, 0)
	cam.fov = 78.0
	cam.current = true
	player.add_child(cam)

	var torch := SpotLight3D.new()
	torch.name = "Flashlight"
	torch.spot_range = 20.0
	torch.spot_angle = 34.0
	torch.light_energy = 4.5
	torch.light_color = Color(1.0, 0.97, 0.9)
	torch.shadow_enabled = true
	cam.add_child(torch)

	# Start at the entrance, facing north into the building.
	player.position = Vector3(entrance_x, 0.1, b_zmin + 1.5)
	player.rotation_degrees.y = 180.0

	var player_script_path := scripts_path.path_join("hospital_player.gd")
	if ResourceLoader.exists(player_script_path):
		player.set_script(load(player_script_path))
	else:
		print("Eslatma: %s topilmadi — WASD uchun hospital_player.gd kerak." % player_script_path)
	add_child(player)
	_player = player


func create_debug_camera() -> void:
	var cam := Camera3D.new()
	cam.name = "DebugTopDownCamera"
	var highest: float = max(b_xmax - b_xmin, b_zmax - b_zmin)
	cam.position = Vector3(0, highest * 1.1, (b_zmin + b_zmax) / 2.0)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.far = highest * 5.0
	cam.current = true
	add_child(cam)


# =========================
#  MONSTER + HORROR DIRECTOR
# =========================
func spawn_monster_system() -> void:
	var monster = create_monster(Vector3(0.0, 0.1, b_zmax - 2.0))
	if monster == null:
		return
	# Patrol up and down the corridor.
	var pts: Array[Vector3] = [
		Vector3(0.0, 0.1, b_zmax - 2.0),
		Vector3(0.0, 0.1, 4.0),
		Vector3(0.0, 0.1, -2.0),
		Vector3(0.0, 0.1, 4.0),
	]
	monster.patrol_points = pts
	var glimpse := Vector3(0.0, 0.1, 5.0)   # down the corridor, visible from the entrance

	var dir_script_path := scripts_path.path_join("horror_director.gd")
	if not ResourceLoader.exists(dir_script_path):
		print("MODEL TOPILMADI: %s (director yo'q)" % dir_script_path)
		monster.active = true
		monster.visible = true
		return
	var director = Node.new()
	director.name = "HorrorDirector"
	director.set_script(load(dir_script_path))
	director.intro_duration = monster_intro_seconds
	director.setup(monster, _player, _ceiling_lamps, glimpse)
	add_child(director)


func create_monster(pos: Vector3) -> Node:
	var ai_script_path := scripts_path.path_join("monster_ai.gd")
	if not ResourceLoader.exists(ai_script_path):
		print("MODEL TOPILMADI: %s (monster_ai.gd yo'q)" % ai_script_path)
		return null

	var body := CharacterBody3D.new()
	body.name = "Monster"
	var collider := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.8
	capsule.radius = 0.4
	collider.shape = capsule
	collider.position.y = 0.9
	body.add_child(collider)

	var model := _load_monster_model()
	if model != null:
		model.scale = Vector3(monster_scale, monster_scale, monster_scale)
		body.add_child(model)
		fix_culling(model)
	else:
		print("MODEL TOPILMADI: %s%s(.glb/.fbx) — placeholder figura ishlatilmoqda" % [monster_dir, monster_file])
		var mesh := MeshInstance3D.new()
		mesh.name = "MonsterMesh"
		var cm := CapsuleMesh.new()
		cm.height = 1.8
		cm.radius = 0.4
		mesh.mesh = cm
		mesh.position.y = 0.9
		mesh.material_override = solid_color_material(Color(0.04, 0.04, 0.05))
		body.add_child(mesh)

	body.set_script(load(ai_script_path))
	body.position = pos
	add_child(body)
	return body


func _load_monster_model() -> Node3D:
	if monster_dir.ends_with(".glb") or monster_dir.ends_with(".fbx"):
		if ResourceLoader.exists(monster_dir):
			return (load(monster_dir) as PackedScene).instantiate() as Node3D
		return null
	var dirs := [monster_dir, "res://assets/monster/", "res://models/monster/", "res://models/"]
	for d in dirs:
		for ext in [".glb", ".fbx"]:
			var p: String = d.path_join(monster_file + ext)
			if ResourceLoader.exists(p):
				return (load(p) as PackedScene).instantiate() as Node3D
	var found := _scan_dir_for_model(monster_dir)
	if found != "":
		return (load(found) as PackedScene).instantiate() as Node3D
	return null


func _scan_dir_for_model(dir_path: String) -> String:
	var da := DirAccess.open(dir_path)
	if da == null:
		return ""
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		if not da.current_is_dir():
			var low := fname.to_lower()
			if low.ends_with(".glb") or low.ends_with(".fbx"):
				da.list_dir_end()
				return dir_path.path_join(fname)
		fname = da.get_next()
	da.list_dir_end()
	return ""

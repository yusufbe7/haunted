extends Node3D
## ============================================================================
##  HAUNTED SALVAGE — LARGE HOSPITAL WARD GENERATOR  (Godot 4.7.1)
## ============================================================================
##  Builds one big, walkable hospital ward at runtime from your FBX kit:
##    * large room  (default 20m wide x 16m long x 4m tall)
##    * 4 auto-built walls + a big entrance doorway in the FRONT wall
##    * floor tiled from floor_tile_1.fbx (no gaps — step is measured from the
##      model's real AABB, so it works whatever size your tile actually is)
##    * white ceiling with real ceiling lights
##    * furniture seated ON the floor and CENTERED on its footprint, so nothing
##      floats, sinks, clips a wall, or overlaps another object
##    * PBR bed material from your Bed_* texture set
##    * first-person camera at 1.7m, wide FOV, ready for WASD movement
##
##  Every model load is guarded: a missing FBX prints
##      "MODEL TOPILMADI: <path>"
##  and the rest of the room keeps generating.
## ============================================================================

# =========================
#  CONFIG  (tweak in the Inspector — no code changes needed)
# =========================
@export_group("Room size (meters)")
@export var room_width: float = 20.0     # X — eni
@export var room_length: float = 16.0    # Z — uzunligi
@export var room_height: float = 4.0     # Y — balandligi
@export var wall_thickness: float = 0.2

@export_group("Entrance door (front wall)")
@export var door_width: float = 2.4
@export var door_height: float = 2.6

@export_group("Assets")
## Primary folder with your .fbx files. Extra folders are tried as fallback,
## so the same script works whether your models live in res://models/ or in
## res://assets/hospital_kit/.
@export var models_path: String = "res://models/"
@export var scripts_path: String = "res://scripts/"
## Folder with the Bed_BaseColor.png / Bed_Normal.png / ... texture set.
@export var bed_texture_dir: String = "res://models/textures/bed/"

@export_group("Debug")
## Fixed camera high above the room, looking straight down. Handy for checking
## the layout. Ships OFF so the game is playable in first person.
@export var debug_top_down: bool = false

# Folders searched, in order, when resolving a model / texture.
const FALLBACK_MODEL_DIRS := ["res://models/", "res://assets/hospital_kit/"]
const FALLBACK_TEX_DIRS := ["res://models/textures/bed/", "res://assets/hospital_kit/textures/bed/"]

# Some kits name the same asset differently — try each spelling.
const NAME_ALIASES := {
	"Magazine_1": ["Magazine_1", "Magazine1"],
	"floor_tile_1": ["floor_tile_1", "floor_tile"],
	"ceiling_light": ["ceiling_light", "CeilingLight"],
}

var _models: Dictionary = {}   # logical name -> PackedScene (only ones found)
var _bed_material: StandardMaterial3D = null


# =========================
#  ENTRY POINT
# =========================
func _ready() -> void:
	_ensure_input_actions()
	create_lighting()
	create_floor_tiles()
	create_ceiling()
	create_walls()
	place_furniture()
	if debug_top_down:
		create_debug_camera()
	else:
		create_camera()
	print("Hospital ward ready: %.1fm x %.1fm x %.1fm" % [room_width, room_length, room_height])


## Register WASD + interact here too, so movement and the door still work even
## if a spawned node's own _ready timing differs. Existing bindings are kept.
func _ensure_input_actions() -> void:
	var binds := {
		"move_forward": KEY_W,
		"move_back": KEY_S,
		"move_left": KEY_A,
		"move_right": KEY_D,
		"interact": KEY_E,
	}
	for action in binds:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var ev := InputEventKey.new()
		ev.keycode = binds[action]
		InputMap.action_add_event(action, ev)


# =========================
#  ASSET LOADING  (graceful — never crashes on a missing file)
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


## Instance a model, add it to the tree, disable backface culling (so interior
## faces stay visible) and return it. Returns null if the model is missing.
func spawn_model(base_name: String, rot_y_deg: float = 0.0, parent: Node3D = self) -> Node3D:
	var packed := get_model(base_name)
	if packed == null:
		return null
	var inst: Node3D = packed.instantiate()
	parent.add_child(inst)
	inst.rotation_degrees.y = rot_y_deg
	fix_culling(inst)
	return inst


## Many interior kits export one-sided meshes; from inside the room those faces
## get culled and vanish. Make every surface double-sided.
func fix_culling(node: Node) -> void:
	if node is MeshInstance3D and node.mesh:
		for i in range(node.mesh.get_surface_count()):
			var mat := node.get_active_material(i)
			if mat and mat is BaseMaterial3D:
				mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for child in node.get_children():
		fix_culling(child)


# =========================
#  AABB HELPERS  (measure real model size so nothing floats or overlaps)
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


## Center the object's footprint on (x, z) and seat its bottom on bottom_y.
func seat_on_floor(inst: Node3D, x: float, z: float, bottom_y: float = 0.0) -> void:
	if inst == null:
		return
	var box := get_world_aabb(inst)
	var center := box.position + box.size * 0.5
	inst.global_position += Vector3(x - center.x, bottom_y - box.position.y, z - center.z)


## Center the object's footprint on (x, z) and hang it so its TOP is at top_y.
func hang_from(inst: Node3D, x: float, z: float, top_y: float) -> void:
	if inst == null:
		return
	var box := get_world_aabb(inst)
	var center := box.position + box.size * 0.5
	inst.global_position += Vector3(x - center.x, top_y - (box.position.y + box.size.y), z - center.z)


## Center the whole object on a world point (for wall-mounted things like signs).
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
#  GENERIC BOX BUILDER  (walls / ceiling)
# =========================
func create_box(size: Vector3, pos: Vector3, color: Color, with_collision: bool = true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	mat.metallic = 0.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # visible from inside the room
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


# =========================
#  FLOOR  (tiled from floor_tile_1.fbx, gap-free)
# =========================
func create_floor_tiles() -> void:
	# One invisible collision slab so the player always has solid ground.
	var floor_body := StaticBody3D.new()
	floor_body.name = "FloorCollision"
	add_child(floor_body)
	var fshape := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(room_width, 0.2, room_length)
	fshape.shape = fbox
	fshape.position = Vector3(0, -0.1, 0)   # top surface at y = 0
	floor_body.add_child(fshape)

	# Measure one tile to get its true footprint, then tile edge-to-edge.
	var sample := spawn_model("floor_tile_1")
	if sample == null:
		# Fallback: light tiled-looking box so the room still has a floor.
		create_box(Vector3(room_width, 0.05, room_length), Vector3(0, -0.025, 0),
			Color(0.85, 0.86, 0.88), false)
		return

	var tile := get_world_aabb(sample)
	var step_x: float = max(tile.size.x, 0.5)
	var step_z: float = max(tile.size.z, 0.5)
	sample.queue_free()   # remove the probe; real grid is spawned below

	var cols: int = int(ceil(room_width / step_x))
	var rows: int = int(ceil(room_length / step_z))
	var start_x: float = -room_width / 2.0 + step_x / 2.0
	var start_z: float = -room_length / 2.0 + step_z / 2.0

	for c in range(cols):
		for r in range(rows):
			var t := spawn_model("floor_tile_1")
			if t == null:
				continue
			seat_on_floor(t, start_x + c * step_x, start_z + r * step_z, 0.0)


# =========================
#  CEILING  (white slab + real ceiling lights)
# =========================
func create_ceiling() -> void:
	create_box(
		Vector3(room_width, wall_thickness, room_length),
		Vector3(0, room_height + wall_thickness / 2.0, 0),
		Color(0.97, 0.97, 0.97),
		false)

	# Evenly spaced light fixtures (3 across X, 2 across Z).
	var xs := [-room_width / 4.0, 0.0, room_width / 4.0]
	var zs := [-room_length / 5.0, room_length / 5.0]
	for x in xs:
		for z in zs:
			var fixture := spawn_model("ceiling_light")
			if fixture != null:
				hang_from(fixture, x, z, room_height - 0.02)  # flush under ceiling
			add_ceiling_lamp(Vector3(x, room_height - 0.35, z))


## Real light under a ceiling fixture (the FBX mesh emits nothing by itself).
func add_ceiling_lamp(pos: Vector3) -> void:
	var lamp := OmniLight3D.new()
	lamp.position = pos
	lamp.light_color = Color(1.0, 0.99, 0.95)
	lamp.light_energy = 2.0
	lamp.omni_range = max(room_width, room_length) * 0.75
	lamp.omni_attenuation = 1.2
	lamp.shadow_enabled = true
	add_child(lamp)


# =========================
#  WALLS  (4 walls, front wall has a big doorway + door + exit sign)
# =========================
func create_walls() -> void:
	var half_w := room_width / 2.0
	var half_l := room_length / 2.0
	var h := room_height
	var t := wall_thickness
	var wall_color := Color(0.92, 0.93, 0.94)   # off-white hospital wall

	# LEFT wall  (x = -half_w)
	create_box(Vector3(t, h, room_length), Vector3(-half_w, h / 2.0, 0), wall_color)
	# RIGHT wall (x = +half_w)
	create_box(Vector3(t, h, room_length), Vector3(half_w, h / 2.0, 0), wall_color)
	# BACK wall  (z = -half_l)  — solid
	create_box(Vector3(room_width, h, t), Vector3(0, h / 2.0, -half_l), wall_color)

	# FRONT wall (z = +half_l) — split around a centered doorway.
	var dw := door_width
	var dh := door_height
	var side := (room_width - dw) / 2.0            # width of each side segment
	var side_center := (dw / 2.0) + (side / 2.0)   # x-offset of each segment center
	# left of door
	create_box(Vector3(side, h, t), Vector3(-side_center, h / 2.0, half_l), wall_color)
	# right of door
	create_box(Vector3(side, h, t), Vector3(side_center, h / 2.0, half_l), wall_color)
	# lintel above door
	create_box(Vector3(dw, h - dh, t), Vector3(0, dh + (h - dh) / 2.0, half_l), wall_color)

	create_entrance_door(half_l)


func create_entrance_door(front_z: float) -> void:
	var packed := get_model("door_1")
	if packed != null:
		var door: Node3D = packed.instantiate()
		# Attach the swing script BEFORE entering the tree so its _ready runs.
		var door_script_path := scripts_path.path_join("hospital_door.gd")
		if ResourceLoader.exists(door_script_path):
			door.set_script(load(door_script_path))
		add_child(door)
		fix_culling(door)
		seat_on_floor(door, 0.0, front_z, 0.0)
		# Shift so the hinge sits at the left jamb of the opening.
		var box := get_world_aabb(door)
		door.global_position.x += (-door_width / 2.0) - box.position.x

	# Exit sign above the doorway (slightly inside the room).
	var sign := spawn_model("Exit_sign")
	if sign != null:
		center_at(sign, Vector3(0, door_height + 0.35, front_z - 0.15))


# =========================
#  FURNITURE  (everything centered on its footprint, seated on the floor)
# =========================
func place_furniture() -> void:
	var half_w := room_width / 2.0
	var half_l := room_length / 2.0

	# --- Hospital bed: main area, a little left of centre ---
	var bed := spawn_model("bed", 90.0)
	seat_on_floor(bed, -3.0, -1.0)
	apply_bed_material(bed)
	var bed_top := top_y_of(bed)

	# --- Cabinet near the bed head ---
	seat_on_floor(spawn_model("cabinet_1", 0.0), -6.5, -3.5)
	# --- Two more cabinets along the left wall ---
	seat_on_floor(spawn_model("cabinet_2", 90.0), -half_w + 0.6, 1.0)
	var cab3 := spawn_model("cabinet_3", 90.0)
	seat_on_floor(cab3, -half_w + 0.6, 3.5)

	# --- Chair beside the bed ---
	seat_on_floor(spawn_model("chair", -90.0), -0.6, 0.5)

	# --- IV stand + bag beside the bed ---
	var iv_holder := spawn_model("IV_Bag_holder")
	seat_on_floor(iv_holder, -5.0, 0.5)
	var iv_bag := spawn_model("IV_Bag")
	hang_from(iv_bag, -5.0, 0.5, top_y_of(iv_holder) - 0.1)

	# --- Bench along the back wall ---
	seat_on_floor(spawn_model("bench", 0.0), 4.0, -half_l + 0.9)

	# --- Magazine resting on top of the low cabinet ---
	var mag := spawn_model("Magazine_1", 20.0)
	seat_on_floor(mag, -half_w + 0.6, 3.5, top_y_of(cab3))

	# --- door_2 available for a future second exit (left unused for now) ---


# =========================
#  BED MATERIAL  (PBR from your Bed_* texture set)
# =========================
func apply_bed_material(bed: Node3D) -> void:
	if bed == null:
		return
	var mat := _get_bed_material()
	if mat == null:
		return
	_apply_material_recursive(bed, mat)


func _get_bed_material() -> StandardMaterial3D:
	if _bed_material != null:
		return _bed_material

	var base := _load_tex("Bed_BaseColor")
	if base == null:
		print("MODEL TOPILMADI: Bed_BaseColor.png (bed keeps its default material)")
		return null

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = base
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var metal := _load_tex("Bed_Metallic")
	if metal != null:
		mat.metallic = 1.0
		mat.metallic_texture = metal

	var rough := _load_tex("Bed_Roughness")
	if rough != null:
		mat.roughness = 1.0
		mat.roughness_texture = rough

	var normal := _load_tex("Bed_Normal")
	if normal != null:
		mat.normal_enabled = true
		mat.normal_texture = normal

	_bed_material = mat
	return mat


func _load_tex(base_name: String) -> Texture2D:
	var dirs: Array = [bed_texture_dir]
	for d in FALLBACK_TEX_DIRS:
		if not dirs.has(d):
			dirs.append(d)
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
#  LIGHTING
# =========================
func create_lighting() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "SunLight"
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)

	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.14, 0.15, 0.17)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.75)
	env.ambient_light_energy = 0.85          # keeps the room from going too dark
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.environment = env
	add_child(world)


# =========================
#  CAMERA / PLAYER  (first-person, 1.7m, WASD-ready)
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
	cam.position = Vector3(0, 1.7, 0)   # eye height
	cam.fov = 78.0                       # wide enough to show the big room
	cam.current = true
	player.add_child(cam)

	# Spawn just inside the entrance, looking into the room.
	player.position = Vector3(0, 0.1, room_length / 2.0 - 2.0)

	# Attach the controller BEFORE entering the tree so its _ready runs
	# (mouse capture + movement setup).
	var player_script_path := scripts_path.path_join("hospital_player.gd")
	if ResourceLoader.exists(player_script_path):
		player.set_script(load(player_script_path))
	else:
		print("Eslatma: %s topilmadi — kamera qo'yildi, lekin WASD uchun hospital_player.gd kerak." % player_script_path)

	add_child(player)


func create_debug_camera() -> void:
	var cam := Camera3D.new()
	cam.name = "DebugTopDownCamera"
	var highest: float = max(room_width, room_length)
	cam.position = Vector3(0, highest * 1.1, 0)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.far = highest * 5.0
	cam.current = true
	add_child(cam)

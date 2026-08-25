extends Node3D
## Hospital room generator — builds the room from your real FBX asset kit
## (floor/wall/ceiling tiles + furniture) instead of placeholder BoxMesh boxes.
##
## Measured directly from your .fbx files:
##   wall/doorway/window tile = 2.0m wide x 2.5m tall
##   floor/ceiling tile       = 2.0m x 2.0m
## so room_width / room_length should stay multiples of 2.0 (12 x 10 already is).

# =========================
# CONFIG
# =========================
@export_group("Room size (meters)")
@export var room_width: float = 12.0
@export var room_length: float = 10.0

@export_group("Assets")
@export var models_path: String = "res://assets/hospital_kit/" # folder with the .fbx files
@export var scripts_path: String = "res://scripts/"            # folder with hospital_door.gd / hospital_player.gd

@export_group("Debug")
## Turn this on to spawn a fixed camera high above the room looking straight
## down, instead of the walkable player. Useful for checking that the room
## itself generated correctly, independent of player physics/collision.
@export var debug_top_down: bool = false

@export_group("Corner tuning")
## tile_corner.fbx rotation per corner, derived from its measured geometry.
## If a corner looks mirrored/rotated once you see it in the editor, nudge
## these by 90/180 — no other code needs to change.
@export var corner_rotation_sw: float = 270.0
@export var corner_rotation_se: float = 180.0
@export var corner_rotation_ne: float = 90.0
@export var corner_rotation_nw: float = 0.0

const TILE_SIZE := 2.0
const WALL_HEIGHT := 2.5

const MODEL_NAMES := [
	"tile_wall", "tile_wall_half", "tile_corner", "tile_doorway_1", "tile_doorway_2",
	"tile_window", "floor_tile_1", "floor_tile_2", "ceiling_tile", "ceiling_light",
	"bed", "bench", "cabinet_1", "cabinet_2", "cabinet_3", "chair", "table",
	"door_1", "door_2", "Exit_sign", "IV_Bag", "IV_Bag_holder", "Magazine1",
	"pillar", "wheel_chair"
]

## Simple box colliders built in code, sized from the real measured geometry
## of each model. This sidesteps the Jolt "Need triangles to create a mesh
## shape" crash that happens when an imported concave/trimesh collider gets
## instanced many times — no per-file Import setup needed at all.
const COLLISION_BOXES := {
	"tile_wall": [{"size": Vector3(2.0, 2.5, 0.18), "offset": Vector3(0, 1.25, 0)}],
	"tile_wall_half": [{"size": Vector3(1.0, 2.5, 0.18), "offset": Vector3(0, 1.25, 0)}],
	"tile_window": [{"size": Vector3(2.0, 2.5, 0.18), "offset": Vector3(0, 1.25, 0)}],
	"tile_corner": [
		{"size": Vector3(1.0, 2.5, 0.18), "offset": Vector3(0.5, 1.25, 0)},
		{"size": Vector3(0.18, 2.5, 1.9), "offset": Vector3(0, 1.25, -0.95)},
	],
	"tile_doorway_1": [
		{"size": Vector3(2.0, 0.5, 0.18), "offset": Vector3(0, 2.25, 0)},
		{"size": Vector3(0.2, 2.0, 0.18), "offset": Vector3(-0.9, 1.0, 0)},
		{"size": Vector3(0.2, 2.0, 0.18), "offset": Vector3(0.9, 1.0, 0)},
	],
	"tile_doorway_2": [
		{"size": Vector3(3.0, 0.5, 0.18), "offset": Vector3(0, 2.25, 0)},
		{"size": Vector3(0.7, 2.0, 0.18), "offset": Vector3(-1.15, 1.0, 0)},
		{"size": Vector3(0.7, 2.0, 0.18), "offset": Vector3(1.15, 1.0, 0)},
	],
	"floor_tile_1": [{"size": Vector3(2.0, 0.1, 2.0), "offset": Vector3(0, 0.05, 0)}],
	"floor_tile_2": [{"size": Vector3(2.0, 0.1, 2.0), "offset": Vector3(0, 0.05, 0)}],
	"bed": [{"size": Vector3(1.42, 1.18, 3.21), "offset": Vector3(-0.01, 0.09, -0.04)}],
	"bench": [{"size": Vector3(2.36, 1.27, 0.78), "offset": Vector3(0, -0.11, 0.03)}],
	"cabinet_1": [{"size": Vector3(2.01, 0.86, 0.78), "offset": Vector3(0, -0.02, -0.27)}],
	"cabinet_2": [{"size": Vector3(1.01, 0.65, 0.49), "offset": Vector3(0.02, 0.0, -0.12)}],
	"cabinet_3": [{"size": Vector3(0.65, 0.79, 0.54), "offset": Vector3(0, -0.11, -0.16)}],
	"chair": [{"size": Vector3(0.82, 1.40, 0.97), "offset": Vector3(0, -0.12, 0.01)}],
	"table": [{"size": Vector3(2.41, 1.05, 1.62), "offset": Vector3(0.02, -0.24, 0.01)}],
	"wheel_chair": [{"size": Vector3(1.01, 1.35, 1.49), "offset": Vector3(0, 0.25, 0.14)}],
	"IV_Bag_holder": [{"size": Vector3(0.64, 2.00, 0.63), "offset": Vector3(0, -0.15, 0)}],
	"door_1": [{"size": Vector3(1.09, 2.02, 0.13), "offset": Vector3(0.45, 0.99, 0)}],
	"door_2": [{"size": Vector3(1.00, 2.00, 0.08), "offset": Vector3(0.50, 1.0, 0)}],
}

var models: Dictionary = {}
var room_cols: int
var room_rows: int


func _ready() -> void:
	room_cols = max(3, int(round(room_width / TILE_SIZE)))
	room_rows = max(3, int(round(room_length / TILE_SIZE)))
	room_width = room_cols * TILE_SIZE   # snap to the tile grid
	room_length = room_rows * TILE_SIZE

	load_models()
	generate_hospital()
	create_lighting()
	if debug_top_down:
		spawn_debug_camera()
	else:
		spawn_player()


func spawn_debug_camera() -> void:
	var cam := Camera3D.new()
	cam.name = "DebugTopDownCamera"
	var highest = max(room_width, room_length)
	cam.position = Vector3(0, highest * 1.2, 0)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.current = true
	cam.far = highest * 5.0
	add_child(cam)


# =========================
# ASSET LOADING
# =========================
func load_models() -> void:
	for n in MODEL_NAMES:
		var path := models_path.path_join(n + ".fbx")
		if ResourceLoader.exists(path):
			models[n] = load(path)
		else:
			push_warning("Hospital kit: model not found -> %s" % path)


func spawn(model_name: String, pos: Vector3, rot_y_deg: float = 0.0, parent: Node3D = self) -> Node3D:
	if not models.has(model_name):
		return null
	var inst: Node3D = models[model_name].instantiate()
	parent.add_child(inst)
	inst.position = pos
	inst.rotation_degrees.y = rot_y_deg
	add_collision(inst, model_name)
	fix_culling(inst)
	return inst


## Many interior asset kits export meshes with normals facing only one way
## (meant to be seen from outside a building). Since our camera stands
## INSIDE the room, those faces get backface-culled and disappear. This
## makes every surface visible from both sides, no matter which way the
## mesh's normals point.
func fix_culling(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_inst := node as MeshInstance3D
		if mesh_inst.mesh:
			for i in range(mesh_inst.mesh.get_surface_count()):
				var mat := mesh_inst.get_active_material(i)
				if mat and mat is BaseMaterial3D:
					mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for child in node.get_children():
		fix_culling(child)


func add_collision(inst: Node3D, model_name: String) -> void:
	if not COLLISION_BOXES.has(model_name):
		return
	for box in COLLISION_BOXES[model_name]:
		var body := StaticBody3D.new()
		inst.add_child(body)
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = box["size"]
		shape.shape = box_shape
		shape.position = box["offset"]
		body.add_child(shape)


# =========================
# MAIN GENERATION
# =========================
func generate_hospital() -> void:
	build_floor()
	build_ceiling()
	build_walls()
	place_furniture()
	print("Hospital generated! room=%.1fm x %.1fm (%d x %d tiles)" % [room_width, room_length, room_cols, room_rows])


func grid_to_world(col: int, row: int) -> Vector3:
	var x := -room_width / 2.0 + TILE_SIZE * (col + 0.5)
	var z := -room_length / 2.0 + TILE_SIZE * (row + 0.5)
	return Vector3(x, 0.0, z)


func build_floor() -> void:
	for col in range(room_cols):
		for row in range(room_rows):
			var tile_name := "floor_tile_1" if (col + row) % 2 == 0 else "floor_tile_2"
			spawn(tile_name, grid_to_world(col, row))


func build_ceiling() -> void:
	for col in range(room_cols):
		for row in range(room_rows):
			spawn("ceiling_tile", grid_to_world(col, row) + Vector3(0, WALL_HEIGHT, 0))

	# a handful of ceiling lights, evenly spaced
	var light_cols: Array = [1, room_cols - 2] if room_cols > 3 else [int(room_cols / 2.0)]
	var light_rows: Array = [1, room_rows - 2] if room_rows > 3 else [int(room_rows / 2.0)]
	for c in light_cols:
		for r in light_rows:
			spawn("ceiling_light", grid_to_world(c, r) + Vector3(0, WALL_HEIGHT, 0))


func build_walls() -> void:
	var half_w := room_width / 2.0
	var half_l := room_length / 2.0

	# --- corners ---
	spawn("tile_corner", Vector3(-half_w, 0, -half_l), corner_rotation_sw)
	spawn("tile_corner", Vector3(half_w, 0, -half_l), corner_rotation_se)
	spawn("tile_corner", Vector3(half_w, 0, half_l), corner_rotation_ne)
	spawn("tile_corner", Vector3(-half_w, 0, half_l), corner_rotation_nw)

	var door_col := int(room_cols / 2.0)     # south wall: doorway goes here
	var window_col := int(room_cols / 2.0)   # north wall: window goes here
	var window_row := int(room_rows / 2.0)   # east wall: window goes here

	# --- south wall (z = -half_l) — has the door ---
	for col in range(1, room_cols - 1):
		var x := -half_w + TILE_SIZE * (col + 0.5)
		var pos := Vector3(x, 0, -half_l)
		if col == door_col:
			spawn("tile_doorway_1", pos, 0.0)
			place_door(pos)
			spawn("Exit_sign", pos + Vector3(0, 2.3, 0.05), 0.0)
		else:
			spawn("tile_wall", pos, 0.0)

	# --- north wall (z = +half_l) — solid, one window ---
	for col in range(1, room_cols - 1):
		var x := -half_w + TILE_SIZE * (col + 0.5)
		var pos := Vector3(x, 0, half_l)
		if col == window_col:
			spawn("tile_window", pos, 180.0)
		else:
			spawn("tile_wall", pos, 180.0)

	# --- west wall (x = -half_w) — solid ---
	for row in range(1, room_rows - 1):
		var z := -half_l + TILE_SIZE * (row + 0.5)
		spawn("tile_wall", Vector3(-half_w, 0, z), 90.0)

	# --- east wall (x = +half_w) — one window ---
	for row in range(1, room_rows - 1):
		var z := -half_l + TILE_SIZE * (row + 0.5)
		var pos := Vector3(half_w, 0, z)
		if row == window_row:
			spawn("tile_window", pos, 270.0)
		else:
			spawn("tile_wall", pos, 270.0)


func place_door(doorway_pos: Vector3) -> void:
	# door_1.fbx pivots at its hinge edge, so rotating it swings it open.
	# This offset seats it inside the 2m opening — nudge x if it clips the frame.
	var door_offset := Vector3(-1.0, 0, 0)
	var door := spawn("door_1", doorway_pos + door_offset, 0.0)
	if door:
		var script := load(scripts_path.path_join("hospital_door.gd"))
		if script:
			door.set_script(script)


# =========================
# FURNITURE
# (positions offset by each model's measured bottom-to-pivot distance,
#  so nothing floats or sinks into the floor)
# =========================
func place_furniture() -> void:
	var half_w := room_width / 2.0
	var half_l := room_length / 2.0

	# patient bed against the back (north) wall
	var bed_pos := Vector3(-half_w + 2.2, 0.504, half_l - 1.0)
	spawn("bed", bed_pos, 180.0)

	# IV stand + bag beside the bed
	var iv_pos := bed_pos + Vector3(1.3, 0, -0.3)
	spawn("IV_Bag_holder", Vector3(iv_pos.x, 1.152, iv_pos.z))
	spawn("IV_Bag", Vector3(iv_pos.x, 1.75, iv_pos.z))  # hook height is approximate

	# wheelchair near the foot of the bed
	spawn("wheel_chair", bed_pos + Vector3(1.6, -0.074, 1.4), -30.0)

	# cabinets along the west wall
	spawn("cabinet_1", Vector3(-half_w + 0.4, 0.453, -half_l + 1.5), 90.0)
	spawn("cabinet_2", Vector3(-half_w + 0.4, 0.323, -half_l + 3.5), 90.0)
	spawn("cabinet_3", Vector3(-half_w + 0.4, 0.506, -half_l + 5.5), 90.0)

	# waiting bench along the east wall
	spawn("bench", Vector3(half_w - 0.5, 0.739, -half_l + 2.0), -90.0)

	# small nurse table + chair near the door
	var table_pos := Vector3(half_w - 1.8, 0.765, -half_l + 1.6)
	spawn("table", table_pos, 0.0)
	spawn("chair", table_pos + Vector3(0, -0.765 + 0.817, 0.9), 180.0)
	spawn("Magazine1", table_pos + Vector3(0.2, 0.285, -0.1), 15.0)


# =========================
# LIGHTING (same idea as your original script)
# =========================
func create_lighting() -> void:
	var light := DirectionalLight3D.new()
	light.name = "HospitalLight"
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.light_energy = 1.0
	light.shadow_enabled = true
	add_child(light)

	var world := WorldEnvironment.new()
	world.name = "WorldEnvironment"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.08, 0.08, 0.08)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.25, 0.25, 0.25)
	environment.ambient_light_energy = 0.7
	world.environment = environment
	add_child(world)


# =========================
# PLAYER (walkable, replaces the static camera)
# =========================
func spawn_player() -> void:
	var player := CharacterBody3D.new()
	player.name = "Player"

	var collider := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.height = 1.7
	shape.radius = 0.35
	collider.shape = shape
	collider.position.y = 0.85
	player.add_child(collider)

	var cam := Camera3D.new()
	cam.name = "PlayerCamera"
	cam.position = Vector3(0, 1.6, 0)
	cam.current = true
	cam.fov = 75.0
	player.add_child(cam)

	player.position = Vector3(0, 0.1, room_length / 2.0 - 2.0)  # near the back wall
	player.rotation_degrees.y = 180.0                            # facing the door

	var script := load(scripts_path.path_join("hospital_player.gd"))
	if script:
		player.set_script(script)

	add_child(player)

extends OmniLight3D
class_name FlickerLight
## A broken / failing ceiling tube. Randomly drops out and buzzes back,
## which reads as a neglected, haunted hospital. Attach to an OmniLight3D.

@export var on_energy: float = 1.6
@export var off_energy: float = 0.0
@export var on_chance: float = 0.72      # how often it's lit vs dark
@export var min_interval: float = 0.04
@export var max_interval: float = 0.6

var _timer: float = 0.0
var _next: float = 0.1


func _ready() -> void:
	if on_energy <= 0.0:
		on_energy = light_energy
	_next = randf_range(min_interval, max_interval)


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= _next:
		_timer = 0.0
		_next = randf_range(min_interval, max_interval)
		light_energy = on_energy if randf() < on_chance else off_energy

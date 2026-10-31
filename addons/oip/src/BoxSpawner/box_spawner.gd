@tool
class_name BoxSpawner
extends ResizableNode3D

## The box scene to spawn (must be a Box-derived PackedScene).
@export var scene: PackedScene
## When enabled, stops spawning new boxes.
@export var disable: bool = false:
	set(value):
		if value == disable:
			return
		disable = value
		if is_inside_tree():
			_change_texture()
			if not disable:
				_reset_spawn_cycle()

@export_group("Box")
## The color applied to spawned boxes.
@export var box_color: Color = Color.WHITE:
	set(value):
		box_color = value
## Mass applied to spawned boxes, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var mass: float = 10.0
## Initial velocity applied to spawned boxes.
@export var initial_linear_velocity: Vector3 = Vector3.ZERO

@export_subgroup("Random Size")
## Enable random sizing for spawned boxes within min/max range.
@export var random_size: bool = false
## Minimum size for randomly sized boxes (X, Y, Z dimensions).
@export var random_size_min: Vector3 = Vector3(0.4, 0.3, 0.3)
## Maximum size for randomly sized boxes (X, Y, Z dimensions).
@export var random_size_max: Vector3 = Vector3(0.8, 0.5, 0.5)

@export_subgroup("Random Mass")
## Enable random mass for spawned boxes within min/max range.
@export var random_mass: bool = false
## Minimum mass for randomly massed boxes, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var random_mass_min: float = 5.0
## Maximum mass for randomly massed boxes, in kilograms.
@export_custom(PROPERTY_HINT_NONE, "suffix:kg") var random_mass_max: float = 15.0

@export_group("Spawn Rate")
## Number of boxes spawned per minute (0-1000).
@export var boxes_per_minute: int = 45:
	set(value):
		value = clamp(value, 0, 1000)
		boxes_per_minute = value

## When true, boxes spawn at a fixed rate. When false, spawn times vary randomly.
@export var fixed_rate: bool = true
## Optional conveyor reference. Spawning pauses when conveyor speed is zero.
@export var conveyor: Node3D = null:
	set(value):
		conveyor = value
		if not value:
			_conveyor_stopped = false

var _scan_interval: float = 0.0
var _conveyor_stopped: bool = false
var _next_spawn_time: float = 0.0
var _spawn_counter: int = 0
var _first_spawn_done: bool = false
var _infeed_blocked: bool = false
var _spawn_shape := BoxShape3D.new()
var _spawn_query := PhysicsShapeQueryParameters3D.new()

@onready var _preview_mesh: MeshInstance3D = $MeshInstance3D
@onready var disabled_box_texture: MeshInstance3D = $MeshInstance3D2
@onready var _preview_collision: CollisionShape3D = $Area3D/CollisionShape3D

func _init() -> void:
	super._init()
	size_default = Vector3(0.6, 0.4, 0.4)

func _enter_tree() -> void:
	super._enter_tree()
	_reset_spawn_cycle()

func _ready() -> void:
	Simulation.started.connect(_on_simulation_started)
	Simulation.stopped.connect(_on_simulation_ended)
	if not Engine.is_editor_hint():
		_preview_mesh.visible = false
	_on_size_changed()
	_change_texture()

func _on_size_changed() -> void:
	if is_instance_valid(_preview_mesh):
		_preview_mesh.scale = size * 0.5
	if is_instance_valid(disabled_box_texture):
		disabled_box_texture.scale = size * 0.501
	if is_instance_valid(_preview_collision):
		var box_shape := _preview_collision.shape as BoxShape3D
		if box_shape:
			box_shape.size = size

func _physics_process(delta: float) -> void:
	if conveyor and Simulation.is_running() and &"speed" in conveyor:
		_conveyor_stopped = conveyor.speed == 0

	if disable or _conveyor_stopped or not Simulation.is_running():
		return
	
	_scan_interval += delta

	# A spawn that finds its volume occupied is not skipped but retried every tick, so the
	# box appears as soon as the infeed clears — the schedule only advances on success.
	if not _first_spawn_done:
		if _spawn_box():
			_first_spawn_done = true
			_spawn_counter += 1
			_scan_interval = 0.0

	if fixed_rate:
		var time_between: float = 60.0 / float(boxes_per_minute)
		if _scan_interval >= time_between:
			if _spawn_box():
				_scan_interval -= time_between
			else:
				_scan_interval = time_between  # owe one spawn, not a backlog that bursts out later
	else:
		if _scan_interval >= _next_spawn_time and _spawn_box():
			_spawn_counter += 1
			if _spawn_counter >= boxes_per_minute:
				_reset_spawn_cycle()
			else:
				_next_spawn_time = _scan_interval + (60.0 / boxes_per_minute) * randf_range(0.5, 1.5)

## Spawns one box; returns false, spawning nothing, while another body occupies the spawn volume.
func _spawn_box() -> bool:
	var box_size: Vector3 = size
	if random_size:
		var x := randf_range(random_size_min.x, random_size_max.x)
		var y := randf_range(random_size_min.y, random_size_max.y)
		var z := randf_range(random_size_min.z, random_size_max.z)
		box_size = Vector3(x, y, z)

	if not _spawn_volume_clear(box_size):
		if not _infeed_blocked:
			_infeed_blocked = true
			print("BoxSpawner: infeed blocked — spawn volume occupied, waiting")
		return false
	if _infeed_blocked:
		_infeed_blocked = false
		print("BoxSpawner: infeed clear")

	var box := scene.instantiate() as Box
	box.size = box_size

	if random_mass:
		box.mass = randf_range(random_mass_min, random_mass_max)
	else:
		box.mass = mass

	box.rotation = rotation
	box.position = position
	box.initial_linear_velocity = initial_linear_velocity
	box.color = box_color
	box.instanced = true
	add_child(box, true)
	box.owner = get_tree().edited_scene_root
	return true

## True when no box (RigidBody3D on the box layers) overlaps the volume a new box would occupy.
## A real infeed cannot place a box where one already is; without this check a backed-up
## line gets boxes spawned inside each other, which the physics then throws around.
func _spawn_volume_clear(box_size: Vector3) -> bool:
	var world := get_world_3d()
	if not world:
		return true
	_spawn_shape.size = box_size
	_spawn_query.shape = _spawn_shape
	# Same placement _spawn_box gives the box: Box is top_level, so these are world coordinates
	# (like the spawn itself, correct while the spawner's parent sits at the origin).
	_spawn_query.transform = Transform3D(Basis.from_euler(rotation), position)
	# All layers, then keep only rigid bodies: boxes are the only ones; belt and blade are static.
	for hit: Dictionary in world.direct_space_state.intersect_shape(_spawn_query, 32):
		if hit.get("collider") is RigidBody3D:
			return false
	return true

func _reset_spawn_cycle() -> void:
	_scan_interval = 0.0
	_spawn_counter = 0
	_first_spawn_done = false
	_next_spawn_time = (60.0 / boxes_per_minute) * randf_range(0.5, 1.5)

func _change_texture() -> void:
	if not is_inside_tree():
		return
	disabled_box_texture.visible = disable

func use() -> void:
	disable = not disable

func _on_simulation_started() -> void:
	if conveyor and &"speed" not in conveyor:
		push_warning("Conveyor reference in " + name + " does not have a speed property")
	_reset_spawn_cycle()

func _on_simulation_ended() -> void:
	_conveyor_stopped = false

extends Node3D

## Camera, input, and presentation stub.
## Commands are constructed locally and are not sent.
## See docs/briefs/netcode-interface-v0.md.

@onready var camera: Camera3D = $Camera

var last_local_intent: GameCommand


func _ready() -> void:
	_frame_map()
	last_local_intent = GameCommand.new(GameCommand.Kind.CLAIM_TILE)


func _frame_map() -> void:
	var map_size := float(SliceConstants.MAP_SIZE)
	var target := Vector3(map_size * 0.5, 0.0, map_size * 0.5)
	# 25° off vertical: orthogonal camera, mild micro-oblique.
	var pitch_deg := 65.0
	var dist := 56.0
	var pitch := deg_to_rad(pitch_deg)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.current = true
	camera.size = map_size + 8.0
	camera.rotation_degrees = Vector3(-pitch_deg, 0.0, 0.0)
	camera.position = target + Vector3(0.0, dist * sin(pitch), dist * cos(pitch))


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_accept"):
		return
	# Placeholder binding. Picking a tile and sending the command come later.
	last_local_intent = GameCommand.new(GameCommand.Kind.CLAIM_TILE)

extends Node3D
## Production mid-realism interchange sample. NO HUD.
## Set capture_on_ready=true (or env CITY_MVP_CAPTURE=1) to write still + quit.

const OUT_S01 := "res://client/assets/techart/roads_interchange/preview/prod-mid-s01-1920x1080.png"
const OUT_S02 := "res://client/assets/techart/roads_interchange/preview/prod-mid-s02-1920x1080.png"
const WARMUP := 24

@export var capture_on_ready: bool = false
@export var capture_s02: bool = false

@onready var cam_s01: Camera3D = $CameraS01
@onready var cam_s02: Camera3D = $CameraS02
@onready var world: Node3D = $World

func _ready() -> void:
	var builders = load("res://client/assets/techart/roads_interchange/scripts/mid_realism_builders.gd").new()
	builders.build_interchange_world(world)
	var do_cap := capture_on_ready or OS.get_environment("CITY_MVP_CAPTURE") == "1"
	if do_cap:
		await _capture_all()

func _capture_all() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	get_viewport().size = Vector2i(1920, 1080)
	for i in WARMUP:
		await get_tree().process_frame
	cam_s01.current = true
	for i in 8:
		await get_tree().process_frame
	_save_viewport(OUT_S01)
	print("[prod-mid-capture] wrote ", OUT_S01)
	if capture_s02 or OS.get_environment("CITY_MVP_CAPTURE_S02") == "1":
		cam_s02.current = true
		for i in 8:
			await get_tree().process_frame
		_save_viewport(OUT_S02)
		print("[prod-mid-capture] wrote ", OUT_S02)
	await get_tree().process_frame
	get_tree().quit()

func _save_viewport(res_path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("null image " + res_path)
		return
	if img.get_format() != Image.FORMAT_RGBA8 and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGBA8)
	var abs_path := ProjectSettings.globalize_path(res_path)
	var err := img.save_png(abs_path)
	print("[prod-mid-capture] path=", abs_path, " ", img.get_width(), "x", img.get_height(), " err=", err)

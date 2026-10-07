extends Node
## GameCity "max quality" showcase driver.
## Renders into a fixed-size SubViewport (independent of the window / Retina scale), so 1080p and 4K
## captures are exact. Interactive mode shows the viewport in the window.
##
## Environment:
##   CITY_SHOWCASE_CAPTURE=1        capture shots then quit
##   CITY_SHOWCASE_SHOTS=a,b        shot names (default: all) ; add _4k for the 3840x2160 variant
##   CITY_SHOWCASE_OUT=/abs/dir     output directory (default: showcase_max/preview)
##   CITY_SHOWCASE_PROFILE=shot|interactive
##   CITY_SHOWCASE_FX=k=v,k=v       feature overrides, e.g. gi=voxel,aa=taa,ssr=false
##   CITY_SHOWCASE_SCALE=0.5        output resolution factor (fast iteration)
##   CITY_SHOWCASE_WARMUP=90        warm-up frames per shot
##   CITY_SHOWCASE_PERF=file.json   append perf rows (60-frame averages) to this file
##   CITY_SHOWCASE_TAG=_x           suffix for output file names (variant comparisons)

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")
const Shots := preload("res://client/assets/techart/showcase_max/scripts/shots.gd")
const Quality := preload("res://client/assets/techart/showcase_max/scripts/quality.gd")
const Lighting := preload("res://client/assets/techart/showcase_max/scripts/lighting.gd")
const World := preload("res://client/assets/techart/showcase_max/scripts/world.gd")

var sv: SubViewport
var scene3d: Node3D
var cam: Camera3D
var light
var world
var fx := {}
var shots := {}
var cur_shot := ""
var warmup := 90
var perf_rows: Array = []
var hud: Label
var interactive_index := 0
var _view_rect: TextureRect

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var prof := OS.get_environment("CITY_SHOWCASE_PROFILE")
	fx = Quality.profile("interactive" if prof == "interactive" else "shot")
	var ov := OS.get_environment("CITY_SHOWCASE_FX")
	if ov != "":
		Quality.parse_overrides(ov, fx)
	if OS.get_environment("CITY_SHOWCASE_WARMUP") != "":
		warmup = int(OS.get_environment("CITY_SHOWCASE_WARMUP"))
	shots = Shots.table()
	var capture := OS.get_environment("CITY_SHOWCASE_CAPTURE") == "1"
	var scale := 1.0
	if OS.get_environment("CITY_SHOWCASE_SCALE") != "":
		scale = float(OS.get_environment("CITY_SHOWCASE_SCALE"))
	Quality.apply_server(fx)
	_make_viewport(Vector2i(int(1920 * scale), int(1080 * scale)))
	_make_scene()
	if capture:
		DisplayServer.window_set_size(Vector2i(640, 360))
		await _capture_all(scale)
		get_tree().quit()
	else:
		_interactive_setup()

func _make_viewport(size: Vector2i) -> void:
	sv = SubViewport.new()
	sv.size = size
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.msaa_3d = Viewport.MSAA_4X
	add_child(sv)
	Quality.apply_viewport(sv, fx)
	RenderingServer.viewport_set_measure_render_time(sv.get_viewport_rid(), true)

func _make_scene() -> void:
	scene3d = Node3D.new()
	scene3d.name = "Scene3D"
	sv.add_child(scene3d)
	cam = Camera3D.new()
	cam.name = "ShowcaseCamera"
	scene3d.add_child(cam)
	cam.current = true
	light = Lighting.new()
	light.make(scene3d)
	world = World.new()
	world.build(scene3d)

func _apply_shot(name: String) -> void:
	cur_shot = name
	var shot: Dictionary = shots[name]
	light.configure(shot["preset"], fx, shot["kind"])
	Shots.make_camera(shot, cam)
	var dusk: bool = shot["preset"] == "dusk"
	world.mats.set_night(1.0 if dusk else 0.0)
	world.mats.set_wet(0.6 if dusk else 0.0)
	if shot.get("dof", false):
		light.set_dof(cam, true, cam.global_position.distance_to(shot["look"]), 120.0, 8.0, 0.12)
	else:
		light.set_dof(cam, false, 0, 0, 0, 0)
	if world.has_method("apply_preset"):
		world.apply_preset(shot["preset"], shot, fx)

func _capture_all(scale: float) -> void:
	var names: Array = []
	var env_shots := OS.get_environment("CITY_SHOWCASE_SHOTS")
	if env_shots != "":
		names = Array(env_shots.split(",", false))
	else:
		names = Shots.ORDER.duplicate()
	var out_dir := OS.get_environment("CITY_SHOWCASE_OUT")
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path(Cfg.PREVIEW_DIR)
	DirAccess.make_dir_recursive_absolute(out_dir)
	for n in names:
		var is_4k: bool = String(n).ends_with("_4k")
		var base: String = String(n).trim_suffix("_4k")
		if not shots.has(base):
			push_error("unknown shot " + base)
			continue
		var w := int(shots[base]["w"] * scale)
		var h := int(shots[base]["h"] * scale)
		if is_4k:
			w = int(3840 * scale)
			h = int(2160 * scale)
		sv.size = Vector2i(w, h)
		_apply_shot(base)
		await _settle(warmup)
		var perf := await _measure(60)
		var img := sv.get_texture().get_image()
		var path := out_dir.path_join(String(n) + OS.get_environment("CITY_SHOWCASE_TAG") + ".png")
		var err := img.save_png(path)
		perf["shot"] = n
		perf["w"] = img.get_width()
		perf["h"] = img.get_height()
		perf["profile"] = fx.get("profile", "shot")
		perf["aa"] = fx.get("aa")
		perf["gi"] = fx.get("gi")
		perf_rows.append(perf)
		print("[capture] ", n, " -> ", path, " ", img.get_width(), "x", img.get_height(), " err=", err,
			" proc_ms=", snappedf(perf["proc_ms"], 0.01), " wall_ms=", snappedf(perf["wall_ms"], 0.01), " gpu_ms=", snappedf(perf["gpu_ms"], 0.01))
	var perf_file := OS.get_environment("CITY_SHOWCASE_PERF")
	if perf_file != "":
		var f := FileAccess.open(perf_file, FileAccess.READ_WRITE if FileAccess.file_exists(perf_file) else FileAccess.WRITE)
		f.seek_end()
		for r in perf_rows:
			f.store_line(JSON.stringify(r))
		f.close()

func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame

## 60-frame average of TIME_PROCESS (task metric), wall-clock frame time and the viewport GPU time.
func _measure(frames: int) -> Dictionary:
	var rid := sv.get_viewport_rid()
	var proc := 0.0
	var gpu := 0.0
	var cpu_r := 0.0
	var t0 := Time.get_ticks_usec()
	for i in frames:
		await get_tree().process_frame
		proc += Performance.get_monitor(Performance.TIME_PROCESS)
		if i < 5 and OS.get_environment("CITY_SHOWCASE_DEBUG") == "1":
			print("  sample ", i, " TIME_PROCESS=", Performance.get_monitor(Performance.TIME_PROCESS), " FPS=", Performance.get_monitor(Performance.TIME_FPS), " gpu=", RenderingServer.viewport_get_measured_render_time_gpu(rid), " cpu=", RenderingServer.viewport_get_measured_render_time_cpu(rid))
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		cpu_r += RenderingServer.viewport_get_measured_render_time_cpu(rid)
	var wall := float(Time.get_ticks_usec() - t0) / 1000.0 / float(frames)
	return {
		"proc_ms": proc / frames * 1000.0,
		"wall_ms": wall,
		"gpu_ms": gpu / frames,
		"render_cpu_ms": cpu_r / frames,
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"prims": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"vram_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
	}

# ---------------------------------------------------------------- interactive
func _interactive_setup() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	_view_rect = TextureRect.new()
	_view_rect.texture = sv.get_texture()
	_view_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_view_rect)
	hud = Label.new()
	hud.position = Vector2(12, 8)
	hud.add_theme_color_override("font_color", Color(1, 1, 0.8))
	hud.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	hud.add_theme_constant_override("outline_size", 4)
	add_child(hud)
	_apply_shot(Shots.ORDER[0])

func _process(_dt: float) -> void:
	if hud == null:
		return
	hud.text = "%s | %s | proc %.1f ms | gpu %.1f ms | keys 1-6 shots, T tier (shot/interactive)" % [
		cur_shot, fx.get("profile"), Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		RenderingServer.viewport_get_measured_render_time_gpu(sv.get_viewport_rid())]

func _unhandled_key_input(ev: InputEvent) -> void:
	if not (ev is InputEventKey) or not ev.pressed:
		return
	var k := (ev as InputEventKey).keycode
	if k >= KEY_1 and k <= KEY_6:
		_apply_shot(Shots.ORDER[k - KEY_1])
	elif k == KEY_T:
		var nxt := "interactive" if fx.get("profile") == "shot" else "shot"
		fx = Quality.profile(nxt)
		Quality.apply_server(fx)
		Quality.apply_viewport(sv, fx)
		_apply_shot(cur_shot)

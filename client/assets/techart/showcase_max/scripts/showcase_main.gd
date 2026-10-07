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
##   CITY_SHOWCASE_BENCH=1          run the feature ablation plan (bench_plan.gd) instead of the shots
##   CITY_SHOWCASE_BENCH_GROUPS=a,b only these groups (gi, fx, sky, aa, shadow, lights, shots, tier)

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")
const Shots := preload("res://client/assets/techart/showcase_max/scripts/shots.gd")
const Quality := preload("res://client/assets/techart/showcase_max/scripts/quality.gd")
const Lighting := preload("res://client/assets/techart/showcase_max/scripts/lighting.gd")
const World := preload("res://client/assets/techart/showcase_max/scripts/world.gd")
const BenchPlan := preload("res://client/assets/techart/showcase_max/scripts/bench_plan.gd")

var sv: SubViewport
var scene3d: Node3D
var cam: Camera3D
var light
var world
var fx := {}
var shots := {}
var cur_shot := ""
var warmup := 240
var perf_rows: Array = []
var hud: Label
var interactive_index := 0
var _view_rect: TextureRect

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		# no renderer: only build the district (data, meshes, materials) and report, so smoke runs stay meaningful
		var holder := Node3D.new()
		add_child(holder)
		var w := World.new()
		w.build(holder)
		print("SHOWCASE_BUILD_OK tris=", w.stats.get("tris", 0), " ", w.data.summary())
		get_tree().quit()
		return
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
	if OS.get_environment("CITY_SHOWCASE_BENCH") == "1":
		DisplayServer.window_set_size(Vector2i(640, 360))
		await _run_bench()
		get_tree().quit()
	elif capture:
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
	# SDFGI cascades are centred on the camera, so the camera distance picks the cascade cell size;
	# the shadow range follows the camera depth range.
	if not fx.has("sdfgi_cell_user"):
		fx["sdfgi_cell"] = float(shot.get("sdfgi_cell", fx.get("sdfgi_cell", 0.4)))
	fx["shadow_max"] = float(shot.get("dist", 420.0)) + 150.0 if shot["kind"] == "game" else 900.0
	light.configure(shot["preset"], fx, shot["kind"])
	Shots.make_camera(shot, cam)
	var dusk: bool = shot["preset"] == "dusk"
	world.mats.set_night(1.0 if dusk else 0.0)
	world.mats.set_wet(0.6 if dusk else 0.0)
	if shot.get("dof", false):
		light.set_dof(cam, true, cam.global_position.distance_to(shot["look"]), 120.0, 8.0, 0.12)
	else:
		light.set_dof(cam, false, 0, 0, 0, 0)
	if fx.get("gi", "sdfgi") == "voxel":
		var fcs: Vector3 = shot.get("voxel_center", shot.get("focus", shot.get("look", Vector3.ZERO)))
		var ext := float(fx.get("voxel_extent", shot.get("voxel_extent", 340.0)))
		world.setup_voxel_gi(Vector3(fcs.x, 45.0, fcs.z), Vector3(ext, 120.0, ext), int(shot.get("voxel_subdiv", fx.get("voxel_subdiv", 512))), light.sun)
	else:
		world.disable_voxel_gi()
	if world.has_method("apply_preset"):
		world.apply_preset(shot["preset"], shot, fx, light.tm_params)

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
		perf["draw_ms"] = await _measure_draw(60)
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
			" proc_ms=", snappedf(perf["proc_ms"], 0.01),  " wall_ms=", snappedf(perf["wall_ms"], 0.01), " draw_ms=", snappedf(perf["draw_ms"], 0.01))
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

func _bench_apply(shot_name: String, base_profile: String, ov: Dictionary) -> void:
	fx = Quality.profile(base_profile)
	for k in ov:
		fx[k] = ov[k]
	Quality.apply_server(fx)
	sv.size = Vector2i(1920, 1080)
	Quality.apply_viewport(sv, fx)
	_apply_shot(shot_name)

## One entry per process (CITY_SHOWCASE_BENCH_ONLY=group/tag) so state never accumulates; tools/run_bench.sh adds
## cool-down gaps. Inside the process the reference and the variant are timed in alternating rounds
## (R V V R R V ...), so clock drift on the (passively cooled) M4 hits both equally. The reported ratio is the
## median of the per-round variant/reference ratios. CITY_SHOWCASE_BENCH_LIST=1 prints the entry names and exits.
func _run_bench() -> void:
	if OS.get_environment("CITY_SHOWCASE_BENCH_LIST") == "1":
		for entry in BenchPlan.entries():
			print("BENCH_ENTRY ", entry[0], "/", entry[1])
		return
	var only_entry := OS.get_environment("CITY_SHOWCASE_BENCH_ONLY")
	var docs_dir := ProjectSettings.globalize_path(Cfg.PACK + "/docs")
	var cmp_dir := ProjectSettings.globalize_path(Cfg.PREVIEW_DIR + "/compare")
	DirAccess.make_dir_recursive_absolute(cmp_dir)
	var res_path := docs_dir + "/bench_results.json"
	var crop := Rect2i(700, 330, 640, 360)
	var settle := int(OS.get_environment("CITY_SHOWCASE_BENCH_SETTLE")) if OS.get_environment("CITY_SHOWCASE_BENCH_SETTLE") != "" else 70
	var rounds := 4
	for entry in BenchPlan.entries():
		var group: String = entry[0]
		var tag: String = entry[1]
		if only_entry != "" and only_entry != "%s/%s" % [group, tag]:
			continue
		var shot_name: String = entry[2]
		var ov: Dictionary = entry[3].duplicate()
		var base_profile := "interactive" if ov.get("profile", "") == "interactive" else "shot"
		ov.erase("profile")
		var ref_med: Array = []
		var var_med: Array = []
		var ref_min: Array = []
		var var_min: Array = []
		var ratios: Array = []
		var shot_img: Image = null
		var eff := {}
		var rec_vram := 0.0
		var rec_calls := 0.0
		var rec_prims := 0.0
		var proc_ms := 0.0
		for r in rounds:
			var order: Array = ["ref", "var"] if r % 2 == 0 else ["var", "ref"]
			var this_ref := 0.0
			var this_var := 0.0
			for which in order:
				_bench_apply(shot_name, base_profile, {} if which == "ref" else ov)
				await _settle(settle)
				var m := await _measure_draw2(24)
				if which == "ref":
					ref_med.append(m["med"])
					ref_min.append(m["min"])
					this_ref = m["med"]
				else:
					var_med.append(m["med"])
					var_min.append(m["min"])
					this_var = m["med"]
					rec_vram = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
					rec_calls = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
					rec_prims = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
					eff = {"msaa_3d": sv.msaa_3d, "taa": sv.use_taa, "ssaa": sv.screen_space_aa, "scaling_mode": sv.scaling_3d_mode, "scale": sv.scaling_3d_scale}
					if r == rounds - 1 and entry[4] != "":
						shot_img = sv.get_texture().get_image()
			ratios.append(this_var / maxf(this_ref, 0.001))
		var pm := await _measure(30)
		ratios.sort()
		ref_med.sort()
		var_med.sort()
		var med_ratio: float = (float(ratios[1]) + float(ratios[2])) * 0.5
		var r_med: float = (float(ref_med[1]) + float(ref_med[2])) * 0.5
		var v_med: float = (float(var_med[1]) + float(var_med[2])) * 0.5
		var r_min: float = float(ref_min.min())
		var v_min: float = float(var_min.min())
		var row := {"group": group, "tag": tag, "shot": shot_name, "profile": base_profile, "fx": ov, "effective": eff,
			"med_ms": snappedf(v_med, 0.01), "ref_med_ms": snappedf(r_med, 0.01), "ratio": snappedf(med_ratio, 0.001),
			"min_ms": snappedf(v_min, 0.01), "ref_min_ms": snappedf(r_min, 0.01),
			"delta_med_ms": snappedf(v_med - r_med, 0.01), "delta_min_ms": snappedf(v_min - r_min, 0.01),
			"ratio_rounds": ratios.map(func(x): return snappedf(float(x), 0.001)),
			"proc_ms": snappedf(pm["proc_ms"], 0.01), "wall_ms": snappedf(pm["wall_ms"], 0.01),
			"vram_mb": snappedf(rec_vram, 0.1), "draw_calls": rec_calls, "prims": rec_prims}
		if shot_img != null:
			if entry[4] == "crop":
				shot_img = shot_img.get_region(crop)
			else:
				shot_img.resize(480, 270, Image.INTERPOLATE_LANCZOS)
			shot_img.save_png("%s/%s_%s.png" % [cmp_dir, group, tag])
			row["image"] = "compare/%s_%s.png" % [group, tag]
		var results := {}
		if FileAccess.file_exists(res_path):
			var rf := FileAccess.open(res_path, FileAccess.READ)
			var parsed = JSON.parse_string(rf.get_as_text())
			if parsed is Dictionary:
				results = parsed
		results["%s/%s" % [group, tag]] = row
		var wf := FileAccess.open(res_path, FileAccess.WRITE)
		wf.store_string(JSON.stringify(results, "\t"))
		wf.close()
		print("[bench] ", group, "/", tag, " ", shot_name, " var_med=", row["med_ms"], " ref_med=", row["ref_med_ms"], " ratio=", row["ratio"], " rounds=", row["ratio_rounds"],
			" calls=", row["draw_calls"], " vram=", row["vram_mb"])

func _measure_draw(frames: int) -> float:
	var d := await _measure_draw2(frames)
	return d["med"]

## 8 chunks of draws with the GPU queue drained between chunks. `min` is the burst figure (least affected by the
## M4's thermal throttling, used for ablation deltas); `med` is the median chunk.
func _measure_draw2(frames: int) -> Dictionary:
	await get_tree().process_frame
	var chunks: Array = []
	var per := maxi(frames / 8, 4)
	for c in 8:
		RenderingServer.force_sync()
		var t0 := Time.get_ticks_usec()
		for i in per:
			RenderingServer.force_draw(false, 0.0)
		RenderingServer.force_sync()
		var img := sv.get_texture().get_image()   # forces the GPU queue to drain
		chunks.append(float(Time.get_ticks_usec() - t0) / 1000.0 / float(per))
	chunks.sort()
	return {"min": chunks[0], "med": (chunks[3] + chunks[4]) * 0.5, "max": chunks[7]}

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
	if world != null and world.mats != null:
		var ph := fmod(Time.get_ticks_msec() / 1000.0 * 0.35, 1.0)
		for sm in world.mats.overlay_mats:
			sm.set_shader_parameter("pulse_phase", ph)
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

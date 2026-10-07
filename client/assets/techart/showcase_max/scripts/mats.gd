extends RefCounted
## Material factory. World materials are PBR (Poly Haven CC0) or shader-driven; overlay materials use the palette.
## Everything with a `night` or `wet` uniform is tracked so presets can flip it in one call.

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")
const SH := Cfg.PACK + "/shaders/"

var m := {}
var night_mats: Array = []
var overlay_mats: Array = []
var wet_mats: Array = []
var _tex_cache := {}

func tex(id: String, kind: String) -> Texture2D:
	var path := "%s/textures/%s_%s.jpg" % [Cfg.PACK, id, kind]
	if _tex_cache.has(path):
		return _tex_cache[path]
	var t := load(path) as Texture2D
	if t == null:
		push_error("missing texture " + path)
	_tex_cache[path] = t
	return t

func shader(name: String) -> Shader:
	return load(SH + name + ".gdshader") as Shader

func pbr(id: String, uv_m: float, params := {}) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = shader("pbr_world")
	sm.set_shader_parameter("t_albedo", tex(id, "diff"))
	sm.set_shader_parameter("t_arm", tex(id, "arm"))
	sm.set_shader_parameter("t_nor", tex(id, "nor"))
	sm.set_shader_parameter("uv_m", uv_m)
	for k in params:
		sm.set_shader_parameter(k, params[k])
	wet_mats.append(sm)
	return sm

func build() -> void:
	var road := ShaderMaterial.new()
	road.shader = shader("road")
	road.set_shader_parameter("t_albedo", tex("asphalt_02", "diff"))
	road.set_shader_parameter("t_arm", tex("asphalt_02", "arm"))
	road.set_shader_parameter("t_nor", tex("asphalt_02", "nor"))
	road.set_shader_parameter("uv_m", 3.2)
	road.set_shader_parameter("half_w", Cfg.C)
	road.set_shader_parameter("half_row", Cfg.H)
	road.set_shader_parameter("park_w", Cfg.PARK_W)
	wet_mats.append(road)
	m["road"] = road
	m["sidewalk"] = pbr("concrete_tiles_02", 2.0, {"curb_band_w": 0.22, "tint": Color(0.86, 0.85, 0.83), "dirt_edge": 0.4, "normal_scale": 1.2})
	m["curb"] = pbr("concrete_floor_worn_001", 2.0, {"tint": Color(0.82, 0.81, 0.78), "tint_var": 0.1})
	m["grass"] = pbr("leafy_grass", 2.6, {"tint": Color(0.62, 0.78, 0.55), "tint_var": 0.28, "macro_scale": 0.03, "rough_mul": 1.0, "normal_scale": 1.4})
	m["terrain"] = pbr("leafy_grass", 3.4, {"tint": Color(0.30, 0.40, 0.32), "tint_var": 0.35, "macro_scale": 0.012, "normal_scale": 1.2})
	m["paving"] = pbr("floor_pattern_02", 2.6, {"tint": Color(0.78, 0.77, 0.75)})
	m["gravel"] = pbr("gravel_embedded_concrete", 2.2, {"tint": Color(0.8, 0.79, 0.77)})
	m["concrete"] = pbr("concrete_floor_worn_001", 3.2, {"tint": Color(0.85, 0.84, 0.82)})
	m["roof_gravel"] = pbr("tarred_gravel", 2.2, {"tint": Color(1.25, 1.25, 1.25), "tint_var": 0.18})
	m["roof_membrane"] = pbr("concrete_floor_worn_001", 3.4, {"tint": Color(1.05, 1.05, 1.02), "tint_var": 0.1, "normal_scale": 0.4})
	m["roof_green"] = pbr("leafy_grass", 2.2, {"tint": Color(0.45, 0.58, 0.36), "tint_var": 0.25})
	m["roof_tile"] = pbr("roof_09", 2.0, {"tint": Color(0.88, 0.8, 0.76), "tint_var": 0.18})
	m["roof_metal"] = pbr("corrugated_iron_02", 1.6, {"tint": Color(0.72, 0.74, 0.76), "tint_var": 0.1, "metallic_val": 0.5})
	m["brick"] = pbr("brick_wall_006", 1.4, {"tint": Color(0.9, 0.82, 0.78)})
	m["brick_stack"] = pbr("brick_wall_006", 1.4, {"tint": Color(0.62, 0.45, 0.4)})
	# --- facades (style: 0 punched R, 1 ribbon C, 2 curtain wall C, 3 industrial I)
	m["fac_R_brick"] = facade(0, "brick_wall_006", 1.5, Color(0.92, 0.85, 0.8), "concrete_floor_worn_001", 2.2, Color(0.78, 0.77, 0.74), 0.8,
		{"win_frac": 0.44, "win_h": 1.5, "sill_h": 0.95, "frame_col": Color(0.9, 0.9, 0.88), "band_col": Color(0.82, 0.8, 0.76), "ground_scale": 1.0})
	m["fac_R_plaster"] = facade(0, "beige_wall_002", 2.2, Color(1.0, 0.96, 0.9), "concrete_floor_worn_001", 2.2, Color(0.8, 0.79, 0.76), 0.9,
		{"win_frac": 0.44, "win_h": 1.5, "sill_h": 0.95, "frame_col": Color(0.93, 0.93, 0.91), "band_col": Color(0.9, 0.88, 0.84), "ground_scale": 1.0})
	m["fac_C_ribbon"] = facade(1, "grey_plaster", 2.0, Color(1.35, 1.35, 1.35), "rectangular_facade_tiles", 1.6, Color(0.95, 0.95, 0.95), 1.0,
		{"frame_col": Color(0.22, 0.24, 0.26), "band_col": Color(0.6, 0.62, 0.64), "ground_scale": 1.3, "glass_metal": 0.55, "glass_rough": 0.04})
	m["fac_C_curtain"] = facade(2, "grey_plaster", 2.0, Color(0.55, 0.58, 0.62), "rectangular_facade_tiles", 1.6, Color(0.8, 0.8, 0.8), 1.2,
		{"frame_col": Color(0.15, 0.17, 0.19), "band_col": Color(0.4, 0.42, 0.44), "ground_scale": 1.4, "glass_metal": 0.45, "glass_rough": 0.05,
		 "glass_col": Color(0.10, 0.24, 0.36), "interior_day": 0.22})
	m["fac_I"] = facade(3, "factory_wall", 3.0, Color(0.78, 0.86, 0.8), "concrete_wall_008", 2.0, Color(0.75, 0.74, 0.72), 1.3,
		{"frame_col": Color(0.3, 0.32, 0.34), "band_col": Color(0.7, 0.7, 0.68), "ground_scale": 1.0, "dirt_amount": 0.8})
	# --- plain props
	m["metal_galv"] = std(Color(0.62, 0.64, 0.66), 0.9, 0.42)
	m["metal_dark"] = std(Color(0.1, 0.11, 0.12), 0.8, 0.38)
	m["metal_rust"] = std(Color(0.45, 0.28, 0.2), 0.6, 0.7)
	m["equip_white"] = std(Color(0.85, 0.87, 0.88), 0.3, 0.45)
	m["equip_grey"] = std(Color(0.5, 0.53, 0.55), 0.5, 0.5)
	# refractive glass: clearcoat + screen-space refraction (balcony rails, terrace rails, lobby skins)
	var gs := StandardMaterial3D.new()
	gs.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gs.albedo_color = Color(0.55, 0.75, 0.82, 0.22)
	gs.metallic = 0.0
	gs.roughness = 0.04
	gs.clearcoat_enabled = true
	gs.clearcoat = 1.0
	gs.clearcoat_roughness = 0.03
	gs.refraction_enabled = true
	gs.refraction_scale = 0.04
	gs.cull_mode = BaseMaterial3D.CULL_DISABLED
	m["glass_simple"] = gs
	m["glass_lobby"] = gs
	m["vcol"] = std(Color.WHITE, 0.0, 0.72, true)
	m["tank"] = std(Color.WHITE, 0.6, 0.4, true)
	m["insulator"] = std(Color.WHITE, 0.0, 0.25, true)
	m["solar"] = std(Color.WHITE, 0.4, 0.18, true)
	m["sign"] = emit_mat(0.12, 3.2)
	m["beacon"] = emit_mat(0.6, 6.0)
	m["lamp"] = emit_mat(0.35, 7.0)
	m["lamp_pole"] = std(Color(0.2, 0.22, 0.24), 0.7, 0.45, true)
	m["wood"] = std(Color(0.38, 0.24, 0.14), 0.0, 0.75)
	m["hedge"] = std(Color.WHITE, 0.0, 0.9, true)
	m["path"] = pbr("gravel_embedded_concrete", 1.6, {"tint": Color(0.9, 0.85, 0.75)})
	var water := std(Color(0.10, 0.36, 0.44), 0.0, 0.03)
	water.metallic_specular = 1.0
	m["water"] = water
	m["container"] = std(Color.WHITE, 0.5, 0.6, true)
	m["bark"] = std(Color.WHITE, 0.0, 0.92, true)
	var fol := ShaderMaterial.new()
	fol.shader = shader("foliage")
	m["foliage"] = fol
	var fence := ShaderMaterial.new()
	fence.shader = shader("fence")
	m["fence_mesh"] = fence
	var cp := StandardMaterial3D.new()
	cp.vertex_color_use_as_albedo = true
	cp.metallic = 0.35
	cp.roughness = 0.26
	cp.clearcoat_enabled = true
	cp.clearcoat = 0.9
	cp.clearcoat_roughness = 0.08
	m["car_paint"] = cp
	m["car_glass"] = std(Color(0.03, 0.05, 0.07), 0.7, 0.05)
	m["car_trim"] = std(Color.WHITE, 0.0, 0.6, true)
	m["car_lights"] = emit_mat(0.5, 3.0)
	var pool := ShaderMaterial.new()
	pool.shader = shader("pool")
	pool.set_shader_parameter("gain", 0.5)
	night_mats.append(pool)
	m["pool"] = pool
	# --- overlay layer (palette colours come from vertex colours, see overlay_builder.gd)
	m["ov_zone"] = overlay(0, 0.95, 1)
	m["ov_zone_frame"] = overlay(0, 0.9, 2)
	m["ov_bracket"] = overlay(0, 1.05, 3)
	m["ov_border"] = overlay(0, 1.2, 4)
	m["ov_curtain"] = overlay(1, 1.1, 3)
	m["ov_power"] = overlay(3, 1.25, 2)
	m["ov_ring"] = overlay(5, 1.2, 5)
	m["ov_pulse"] = overlay(2, 1.0, 6)
	m["ov_badge_rim"] = overlay(0, 1.0, 7)
	m["ov_badge"] = overlay(0, 1.25, 8)
	m["ov_grid"] = overlay(4, 1.0, 0)

func std(col: Color, metal: float, rough: float, vcol := false) -> StandardMaterial3D:
	var sm := StandardMaterial3D.new()
	sm.albedo_color = col
	sm.metallic = metal
	sm.roughness = rough
	sm.vertex_color_use_as_albedo = vcol
	sm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return sm

func emit_mat(day_emit: float, night_emit: float) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = shader("emit_vcol")
	sm.set_shader_parameter("day_emit", day_emit)
	sm.set_shader_parameter("night_emit", night_emit)
	night_mats.append(sm)
	return sm

func facade(style: int, wall_id: String, wall_m: float, wall_tint: Color, base_id: String, base_m: float,
		base_tint: Color, base_h: float, extra := {}) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = shader("facade")
	sm.set_shader_parameter("style", style)
	sm.set_shader_parameter("wall_albedo", tex(wall_id, "diff"))
	sm.set_shader_parameter("wall_arm", tex(wall_id, "arm"))
	sm.set_shader_parameter("wall_nor", tex(wall_id, "nor"))
	sm.set_shader_parameter("wall_m", wall_m)
	sm.set_shader_parameter("wall_tint", wall_tint)
	sm.set_shader_parameter("base_albedo", tex(base_id, "diff"))
	sm.set_shader_parameter("base_arm", tex(base_id, "arm"))
	sm.set_shader_parameter("base_nor", tex(base_id, "nor"))
	sm.set_shader_parameter("base_m", base_m)
	sm.set_shader_parameter("base_tint", base_tint)
	sm.set_shader_parameter("base_h", base_h)
	for k in extra:
		sm.set_shader_parameter(k, extra[k])
	night_mats.append(sm)
	return sm

func overlay(mode: int, gain: float, priority: int) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = shader("overlay")
	sm.set_shader_parameter("mode", mode)
	sm.set_shader_parameter("gain", gain)
	sm.render_priority = priority
	night_mats.append(sm)
	overlay_mats.append(sm)
	return sm

func set_wet(v: float) -> void:
	for sm in wet_mats:
		sm.set_shader_parameter("wet", v)

func set_night(v: float) -> void:
	for sm in night_mats:
		sm.set_shader_parameter("night", v)

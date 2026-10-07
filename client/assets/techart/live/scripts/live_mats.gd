extends RefCounted
## Material factory for the live client, adapted from showcase_max/scripts/mats.gd.
## World materials are the showcase Poly Haven PBR sets through the showcase pbr_world shader;
## facades, roads and overlays use the live shader copies (window state, seam-continuous paint,
## extra overlay slots). Small props share two vertex-colour materials (`prop`, `vcol`) instead of
## one material per finish, so a fully built block stays under ~30 surfaces.

const Cfg := preload("res://client/assets/techart/live/scripts/live_cfg.gd")
const SHOWCASE_SH := Cfg.SHOWCASE + "/shaders/"
const LIVE_SH := Cfg.PACK + "/shaders/"

## Keys whose MeshInstance3D must not cast shadows (flat ground layers and overlays).
const NO_SHADOW_KEYS := ["road", "sidewalk", "curb", "grass", "paving", "gravel", "terrain"]

## Prop colours (albedo through the `prop` / `vcol` vertex-colour materials).
const COL_GALV := Color(0.62, 0.64, 0.66)
const COL_DARK := Color(0.1, 0.11, 0.12)
const COL_RUST := Color(0.45, 0.28, 0.2)
const COL_EQUIP_WHITE := Color(0.85, 0.87, 0.88)
const COL_EQUIP_GREY := Color(0.5, 0.53, 0.55)
const COL_POLE := Color(0.2, 0.22, 0.24)
const COL_WOOD := Color(0.38, 0.24, 0.14)
const COL_SOLAR := Color(0.07, 0.1, 0.2)
const COL_INSULATOR := Color(0.55, 0.38, 0.28)

var m := {}
var overlay_mats: Array = []
var facade_mats: Array = []
var _tex_cache := {}


func tex(id: String, kind: String) -> Texture2D:
	var path := "%s/textures/%s_%s.jpg" % [Cfg.SHOWCASE, id, kind]
	if _tex_cache.has(path):
		return _tex_cache[path]
	var t := load(path) as Texture2D
	if t == null:
		push_error("missing texture " + path)
	_tex_cache[path] = t
	return t


func showcase_shader(name: String) -> Shader:
	return load(SHOWCASE_SH + name + ".gdshader") as Shader


func live_shader(name: String) -> Shader:
	return load(LIVE_SH + name + ".gdshader") as Shader


func pbr(id: String, uv_m: float, params := {}) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = showcase_shader("pbr_world")
	sm.set_shader_parameter("t_albedo", tex(id, "diff"))
	sm.set_shader_parameter("t_arm", tex(id, "arm"))
	sm.set_shader_parameter("t_nor", tex(id, "nor"))
	sm.set_shader_parameter("uv_m", uv_m)
	for k in params:
		sm.set_shader_parameter(k, params[k])
	return sm


func build() -> void:
	var road := ShaderMaterial.new()
	road.shader = live_shader("road_live")
	road.set_shader_parameter("t_albedo", tex("asphalt_02", "diff"))
	road.set_shader_parameter("t_arm", tex("asphalt_02", "arm"))
	road.set_shader_parameter("t_nor", tex("asphalt_02", "nor"))
	road.set_shader_parameter("uv_m", 3.2)
	road.set_shader_parameter("half_w", Cfg.C)
	road.set_shader_parameter("half_row", Cfg.H)
	road.set_shader_parameter("park_w", Cfg.PARK_W)
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
	# --- shared prop finishes (vertex colour = albedo)
	m["prop"] = std(Color.WHITE, 0.55, 0.48, true)
	m["vcol"] = std(Color.WHITE, 0.0, 0.72, true)
	var gs := StandardMaterial3D.new()
	gs.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gs.albedo_color = Color(0.55, 0.75, 0.82, 0.22)
	gs.metallic = 0.0
	gs.roughness = 0.04
	gs.clearcoat_enabled = true
	gs.clearcoat = 1.0
	gs.clearcoat_roughness = 0.03
	gs.cull_mode = BaseMaterial3D.CULL_DISABLED
	m["glass_simple"] = gs
	m["emit"] = emit_mat(0.3, 3.2)
	m["bark"] = std(Color.WHITE, 0.0, 0.92, true)
	var fol := ShaderMaterial.new()
	fol.shader = showcase_shader("foliage")
	m["foliage"] = fol
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
	# --- overlay layer (palette slots come from vertex colours, see live_palette.gd)
	m["ov_field"] = overlay(3, 1.2, 1)
	m["ov_flat"] = overlay(0, 1.0, 2)
	m["ov_curtain"] = overlay(1, 1.1, 3)
	m["ov_pulse"] = overlay(2, 1.0, 6)
	m["ov_badge"] = overlay(0, 1.25, 8)
	m["ov_direct"] = overlay(6, 1.0, 0)
	var hover := ShaderMaterial.new()
	hover.shader = live_shader("hover_live")
	hover.render_priority = 10
	m["hover"] = hover


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
	sm.shader = showcase_shader("emit_vcol")
	sm.set_shader_parameter("day_emit", day_emit)
	sm.set_shader_parameter("night_emit", night_emit)
	return sm


func facade(style: int, wall_id: String, wall_m: float, wall_tint: Color, base_id: String, base_m: float,
		base_tint: Color, base_h: float, extra := {}) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = live_shader("facade_live")
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
	facade_mats.append(sm)
	return sm


func overlay(mode: int, gain: float, priority: int) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = live_shader("overlay_live")
	sm.set_shader_parameter("mode", mode)
	sm.set_shader_parameter("gain", gain)
	sm.render_priority = priority
	overlay_mats.append(sm)
	return sm


func set_palette(pal: PackedVector3Array) -> void:
	for sm in overlay_mats:
		sm.set_shader_parameter("pal", pal)


func set_pulse_phase(phase: float) -> void:
	for sm in overlay_mats:
		sm.set_shader_parameter("pulse_phase", phase)


## Brownout window flash, toggled with the overlay flicker.
func set_flicker(on: bool) -> void:
	for sm in facade_mats:
		sm.set_shader_parameter("flicker", 1.0 if on else 0.0)

extends RefCounted
## Environment, sky, sun and post-processing for the day / dusk presets.
## Every quality-list item is switched through the `fx` dictionary so the benchmark can toggle one at a time.

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")

const HDRI_DAY := Cfg.PACK + "/hdri/kloofendal_48d_partly_cloudy_puresky_2k.hdr"
const HDRI_DUSK := Cfg.PACK + "/hdri/kloppenheim_06_puresky_2k.hdr"

var env: Environment
var we: WorldEnvironment
var sun: DirectionalLight3D
var attrs: CameraAttributesPractical
var sky: Sky
var preset := "day"
var sun_dir_hdri := {}      # preset -> Vector3 unit vector (direction TO the sun) in HDRI space
var _sky_cache := {}

func make(parent: Node3D) -> void:
	env = Environment.new()
	we = WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	parent.add_child(sun)
	attrs = CameraAttributesPractical.new()

## Find the brightest texel of an equirect HDRI and return its direction (Godot panorama convention).
func hdri_sun_dir(path: String) -> Vector3:
	if sun_dir_hdri.has(path):
		return sun_dir_hdri[path]
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null:
		push_error("cannot load HDRI " + path)
		return Vector3(0.3, 0.8, -0.5).normalized()
	img.resize(512, 256, Image.INTERPOLATE_BILINEAR)
	var best := -1.0
	var bx := 0
	var by := 0
	# average over a small window so a single hot pixel does not win
	for y in range(2, 120):
		for x in range(2, 510):
			var s := 0.0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var c := img.get_pixel(x + dx, y + dy)
					s += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
			if s > best:
				best = s
				bx = x
				by = y
	var u := (float(bx) + 0.5) / 512.0
	var v := (float(by) + 0.5) / 256.0
	var theta := (u - 0.5) * TAU
	var alpha := v * PI
	var d := Vector3(sin(alpha) * sin(theta), cos(alpha), -sin(alpha) * cos(theta))
	sun_dir_hdri[path] = d
	print("[lighting] HDRI sun ", path.get_file(), " dir=", d, " elev=", rad_to_deg(asin(d.y)))
	return d

## Light azimuth (yaw degrees) used for the sun; the sky is rotated so the HDRI sun lines up.
func configure(p: String, fx: Dictionary, kind := "game") -> void:
	preset = p
	var day := (p == "day")
	var hdri := HDRI_DAY if day else HDRI_DUSK
	var sd := hdri_sun_dir(hdri)
	var elev := asin(sd.y)
	# desired light azimuth: direction the light travels is -dir_to_sun
	var az_deg: float = float(fx.get("sun_az_day", 215.0)) if day else float(fx.get("sun_az_dusk", 235.0))
	var az := deg_to_rad(az_deg)
	var to_sun := Vector3(sin(az) * cos(elev), sin(elev), -cos(az) * cos(elev))
	sun.look_at_from_position(Vector3.ZERO, -to_sun, Vector3.UP)
	# sky rotation about Y so the HDRI sun direction maps to to_sun
	var hdri_az := atan2(sd.x, -sd.z)
	var sky_yaw := az - hdri_az
	# ---- sky
	var sky_mode: String = fx.get("sky", "panorama")
	sky = Sky.new()
	sky.radiance_size = Sky.RADIANCE_SIZE_512
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	if sky_mode == "panorama":
		var pm := PanoramaSkyMaterial.new()
		pm.panorama = load(hdri)
		pm.energy_multiplier = 1.0 if day else 1.0
		sky.sky_material = pm
		env.sky_rotation = Vector3(0, sky_yaw, 0)
	else:
		var ps := PhysicalSkyMaterial.new()
		ps.rayleigh_coefficient = 2.0 if day else 3.2
		ps.rayleigh_color = Color(0.30, 0.52, 0.95) if day else Color(0.55, 0.38, 0.52)
		ps.mie_coefficient = 0.005 if day else 0.014
		ps.mie_eccentricity = 0.8
		ps.mie_color = Color(0.69, 0.73, 0.82) if day else Color(1.0, 0.62, 0.38)
		ps.turbidity = 6.0 if day else 14.0
		ps.sun_disk_scale = 1.0
		ps.ground_color = Color(0.32, 0.34, 0.33)
		ps.energy_multiplier = 1.0
		sky.sky_material = ps
		env.sky_rotation = Vector3.ZERO
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = float(fx.get("ambient_energy", 0.6 if day else 0.55))
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	# ---- sun
	sun.light_color = Color(1.0, 0.94, 0.84) if day else Color(1.0, 0.58, 0.30)
	sun.light_energy = float(fx.get("sun_energy", 3.1 if day else 2.4))
	sun.light_specular = 1.0
	sun.light_angular_distance = 0.4 if day else 0.9   # soft penumbra
	sun.shadow_enabled = bool(fx.get("shadows", true))
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.4
	sun.shadow_blur = 1.0
	var smode: String = fx.get("shadow_mode", "pssm4")
	match smode:
		"pssm4":
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		"pssm2":
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		_:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_split_1 = 0.12
	sun.directional_shadow_split_2 = 0.3
	sun.directional_shadow_split_3 = 0.6
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_max_distance = float(fx.get("shadow_max", 760.0))
	sun.directional_shadow_fade_start = 0.92
	sun.directional_shadow_pancake_size = 40.0
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	# ---- tonemap
	var tm: String = fx.get("tonemap", "aces")
	match tm:
		"aces": env.tonemap_mode = Environment.TONE_MAPPER_ACES
		"agx": env.tonemap_mode = Environment.TONE_MAPPER_AGX
		"filmic": env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		"reinhard": env.tonemap_mode = Environment.TONE_MAPPER_REINHARDT
		_: env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = float(fx.get("exposure", 1.0 if day else 1.15))
	env.tonemap_white = 6.0
	# ---- screen-space effects
	env.ssao_enabled = bool(fx.get("ssao", true))
	env.ssao_radius = 2.2
	env.ssao_intensity = 2.0
	env.ssao_power = 1.6
	env.ssao_detail = 0.6
	env.ssao_horizon = 0.06
	env.ssao_sharpness = 0.9
	env.ssao_light_affect = 0.25
	env.ssil_enabled = bool(fx.get("ssil", true))
	env.ssil_radius = 5.0
	env.ssil_intensity = 1.0
	env.ssil_sharpness = 0.9
	env.ssil_normal_rejection = 1.0
	env.ssr_enabled = bool(fx.get("ssr", true))
	env.ssr_max_steps = 96
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.4
	# ---- GI
	var gi: String = fx.get("gi", "sdfgi")
	env.sdfgi_enabled = (gi == "sdfgi")
	if env.sdfgi_enabled:
		env.sdfgi_cascades = int(fx.get("sdfgi_cascades", 4))
		env.sdfgi_min_cell_size = float(fx.get("sdfgi_cell", 0.4))
		env.sdfgi_use_occlusion = true
		env.sdfgi_read_sky_light = true
		env.sdfgi_bounce_feedback = 0.6
		env.sdfgi_energy = float(fx.get("sdfgi_energy", 1.0))
		env.sdfgi_normal_bias = 1.1
		env.sdfgi_probe_bias = 1.1
	# ---- fog
	# Ortho game cameras sit hundreds of metres away: distance fog would haze everything, so keep it off there.
	var cine := (kind == "cine")
	env.fog_enabled = bool(fx.get("fog", true)) and cine
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = Color(0.62, 0.72, 0.86) if day else Color(0.95, 0.60, 0.45)
	env.fog_light_energy = 1.0
	env.fog_density = 0.00022 if day else 0.0005
	env.fog_aerial_perspective = 0.35
	env.fog_sun_scatter = 0.25 if day else 0.55
	env.fog_sky_affect = 0.0
	env.volumetric_fog_enabled = bool(fx.get("vfog", true)) and cine
	env.volumetric_fog_density = float(fx.get("vfog_density", 0.0009 if day else 0.0024))
	env.volumetric_fog_albedo = Color(0.9, 0.93, 1.0) if day else Color(1.0, 0.78, 0.62)
	env.volumetric_fog_emission = Color(0, 0, 0)
	env.volumetric_fog_anisotropy = 0.62
	env.volumetric_fog_length = 420.0
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_gi_inject = 0.5
	env.volumetric_fog_ambient_inject = 0.4
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.volumetric_fog_temporal_reprojection_amount = 0.9
	# ---- glow
	env.glow_enabled = bool(fx.get("glow", true))
	env.glow_intensity = 0.55 if day else 0.9
	env.glow_strength = 1.0
	env.glow_bloom = 0.02 if day else 0.08
	env.glow_hdr_threshold = 1.0 if day else 0.8
	env.glow_hdr_scale = 2.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT if day else Environment.GLOW_BLEND_MODE_SCREEN
	# ---- color grade
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.1
	env.adjustment_saturation = 1.0 if day else 1.12
	# ---- camera attributes (auto exposure)
	attrs.auto_exposure_enabled = bool(fx.get("auto_exposure", false))
	attrs.auto_exposure_scale = 0.4
	attrs.auto_exposure_speed = 2.0
	attrs.auto_exposure_min_sensitivity = 40.0
	attrs.auto_exposure_max_sensitivity = 1600.0
	we.camera_attributes = attrs

func set_dof(cam: Camera3D, on: bool, focus_dist: float, far_transition: float, near_transition: float, amount: float) -> void:
	var a := CameraAttributesPractical.new()
	a.auto_exposure_enabled = attrs.auto_exposure_enabled
	a.auto_exposure_scale = attrs.auto_exposure_scale
	a.auto_exposure_speed = attrs.auto_exposure_speed
	a.auto_exposure_min_sensitivity = attrs.auto_exposure_min_sensitivity
	a.auto_exposure_max_sensitivity = attrs.auto_exposure_max_sensitivity
	if on:
		a.dof_blur_far_enabled = true
		a.dof_blur_far_distance = focus_dist * 1.12
		a.dof_blur_far_transition = focus_dist * 0.7
		a.dof_blur_near_enabled = true
		a.dof_blur_near_distance = focus_dist * 0.55
		a.dof_blur_near_transition = focus_dist * 0.3
		a.dof_blur_amount = amount
	cam.attributes = a

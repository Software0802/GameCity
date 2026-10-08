class_name LiveLighting
extends WorldEnvironment

## Day lighting for the live client (client/main.tscn "Env"), the showcase interactive tier
## (showcase_max/scripts/quality.gd "interactive" and lighting.gd "day") applied to the game
## camera: Poly Haven HDRI sky through the clamping sky shader, ACES + Adjustments, SSAO medium,
## glow, no SSIL / SSR / fog, 4096 shadow atlas, MetalFX Temporal at SCALE_3D on the root viewport.
##
## Sun shadow follows the camera (CameraRig) every frame. Orthographic view: one orthographic
## cascade over the camera's tight [near, far] (uniform pixel density over depth, so splitting
## would only spend atlas on the empty space between camera and city); the rig keeps that range
## tight at every pitch, so a 30° tilt stays as sharp as 65°. Perspective street view: four
## parallel splits up to CameraRig.shadow_distance() (a multiple of the focus distance, not the
## far plane, which sits at the horizon cap when the top edge looks at the sky), the first split
## ending just past the nearest visible ground and the rest log-spaced (cascade_splits).
##
## GI: the interactive tier offered SDFGI 3 cascades or no GI. SDFGI re-voxelises static
## geometry when a block mesh is replaced and its cascades are centred on a camera that sits
## hundreds of metres above the city, so the live client runs without GI (GI_MODE) and raises
## the sky ambient a little instead.

const Cfg := preload("res://client/assets/techart/live/scripts/live_cfg.gd")
const SKY_SHADER := Cfg.SHOWCASE + "/shaders/sky_panorama.gdshader"
const HDRI_DAY := Cfg.SHOWCASE + "/hdri/kloofendal_48d_partly_cloudy_puresky_2k.hdr"

## Tonemap parameters the overlay palette is compensated for (live_palette.gd):
## exposure, white, contrast, saturation. Must match _make_environment().
const TM_PARAMS := [1.0, 6.0, 1.1, 1.0]
## Direction to the sun in the day HDRI (brightest 3x3 window at 512x256, the showcase
## lighting.gd hdri_sun_dir algorithm, evaluated 2026-10-08): elevation 47.5°.
const HDRI_SUN_DIR := Vector3(0.379059, 0.736817, -0.559835)
## Light azimuth in degrees (showcase day preset).
const SUN_AZIMUTH_DEG := 215.0
const SUN_ENERGY := 3.1
const SUN_COLOR := Color(1.0, 0.94, 0.84)
const AMBIENT_ENERGY := 0.7
## "none" or "sdfgi".
const GI_MODE := "none"
const SHADOW_ATLAS := 4096
const SCALE_3D := 0.67
const SKY_RADIANCE_CLAMP := 3.0
const SKY_VIEW_CLAMP := 40.0
## Perspective cascades: the first split ends this far past the nearest visible ground
## (as a fraction of the shadow reach, clamped), the next two are log-spaced to the reach.
const SPLIT_NEAR_FACTOR := 1.6
const SPLIT_MIN := 0.04
const SPLIT_MAX := 0.25
const FADE_START_ORTHO := 0.92
const FADE_START_PERSPECTIVE := 0.8

@export var sun_path: NodePath = ^"../Sun"
@export var camera_path: NodePath = ^"../Camera"

var sun: DirectionalLight3D = null
var camera: Camera3D = null


func _ready() -> void:
	sun = get_node_or_null(sun_path) as DirectionalLight3D
	camera = get_node_or_null(camera_path) as Camera3D
	environment = _make_environment()
	var attrs := CameraAttributesPractical.new()
	attrs.auto_exposure_enabled = false
	camera_attributes = attrs
	if sun != null:
		_configure_sun(sun)
	_configure_server()
	if DisplayServer.get_name() != "headless":
		_configure_viewport()
		# presentation.gd sets msaa_3d after its children are ready; MetalFX Temporal already
		# anti-aliases, so the extra MSAA resolve is dropped once the tree has settled.
		_disable_msaa.call_deferred()


func _process(_delta: float) -> void:
	if sun != null and camera != null:
		_update_shadows()


## Shadow mode, reach and splits for the camera's current projection and depth range. A plain
## Camera3D (the view check's stress probe) gets the old rule: reach = far plane.
func _update_shadows() -> void:
	var rig := camera as CameraRig
	if rig == null:
		sun.directional_shadow_max_distance = camera.far
		return
	var reach := rig.shadow_distance()
	if rig.perspective:
		_set_shadow_mode(DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)
		var splits := cascade_splits(rig.shadow_near(), reach)
		sun.directional_shadow_split_1 = splits[0]
		sun.directional_shadow_split_2 = splits[1]
		sun.directional_shadow_split_3 = splits[2]
		sun.directional_shadow_blend_splits = true
		sun.directional_shadow_fade_start = FADE_START_PERSPECTIVE
	else:
		_set_shadow_mode(DirectionalLight3D.SHADOW_ORTHOGONAL)
		sun.directional_shadow_blend_splits = false
		sun.directional_shadow_fade_start = FADE_START_ORTHO
	sun.directional_shadow_max_distance = reach


func _set_shadow_mode(mode: DirectionalLight3D.ShadowMode) -> void:
	if sun.directional_shadow_mode != mode:
		sun.directional_shadow_mode = mode


## Split fractions (of the shadow reach) for four parallel cascades: the first ends
## SPLIT_NEAR_FACTOR × the nearest visible ground depth so the bottom of the screen gets a
## whole cascade, the second and third continue in equal ratios up to the reach.
static func cascade_splits(near_ground: float, reach: float) -> Array[float]:
	var first := SPLIT_MIN
	if reach > 0.0 and is_finite(near_ground):
		first = clampf(SPLIT_NEAR_FACTOR * near_ground / reach, SPLIT_MIN, SPLIT_MAX)
	var ratio := pow(1.0 / first, 1.0 / 3.0)
	return [first, first * ratio, first * ratio * ratio]


func _make_environment() -> Environment:
	var env := Environment.new()
	var sky := Sky.new()
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	var sm := ShaderMaterial.new()
	sm.shader = load(SKY_SHADER)
	sm.set_shader_parameter("hdri", load(HDRI_DAY))
	sm.set_shader_parameter("energy", 1.0)
	sm.set_shader_parameter("radiance_energy", 1.0)
	sm.set_shader_parameter("max_lum_radiance", SKY_RADIANCE_CLAMP)
	sm.set_shader_parameter("max_lum_view", SKY_VIEW_CLAMP)
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# rotate the HDRI so its sun lines up with the light azimuth
	var hdri_az := atan2(HDRI_SUN_DIR.x, -HDRI_SUN_DIR.z)
	env.sky_rotation = Vector3(0.0, deg_to_rad(SUN_AZIMUTH_DEG) - hdri_az, 0.0)
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = AMBIENT_ENERGY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = TM_PARAMS[0]
	env.tonemap_white = TM_PARAMS[1]
	env.ssao_enabled = true
	env.ssao_radius = 2.2
	env.ssao_intensity = 2.0
	env.ssao_power = 1.6
	env.ssao_detail = 0.6
	env.ssao_horizon = 0.06
	env.ssao_sharpness = 0.9
	env.ssao_light_affect = 0.25
	env.ssil_enabled = false
	env.ssr_enabled = false
	env.sdfgi_enabled = GI_MODE == "sdfgi"
	if env.sdfgi_enabled:
		env.sdfgi_cascades = 3
		env.sdfgi_min_cell_size = 1.5
		env.sdfgi_use_occlusion = true
		env.sdfgi_read_sky_light = true
		env.sdfgi_bounce_feedback = 0.6
		env.sdfgi_normal_bias = 1.1
		env.sdfgi_probe_bias = 1.1
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_strength = 1.0
	env.glow_bloom = 0.02
	env.glow_hdr_threshold = 1.0
	env.glow_hdr_scale = 2.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = TM_PARAMS[2]
	env.adjustment_saturation = TM_PARAMS[3]
	return env


func _configure_sun(light: DirectionalLight3D) -> void:
	var elev := asin(HDRI_SUN_DIR.y)
	var az := deg_to_rad(SUN_AZIMUTH_DEG)
	var to_sun := Vector3(sin(az) * cos(elev), sin(elev), -cos(az) * cos(elev))
	light.look_at_from_position(Vector3.ZERO, -to_sun, Vector3.UP)
	light.light_color = SUN_COLOR
	light.light_energy = SUN_ENERGY
	light.light_specular = 1.0
	light.light_angular_distance = 0.4
	light.shadow_enabled = true
	light.shadow_bias = 0.04
	light.shadow_normal_bias = 1.4
	light.shadow_blur = 1.0
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	light.directional_shadow_max_distance = 600.0
	light.directional_shadow_fade_start = FADE_START_ORTHO
	light.directional_shadow_pancake_size = 40.0
	light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	if camera != null:
		_update_shadows()


func _configure_server() -> void:
	RenderingServer.directional_shadow_atlas_set_size(SHADOW_ATLAS, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
	RenderingServer.positional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
	RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_MEDIUM, true, 0.5, 2.0, 50.0, 300.0)
	RenderingServer.environment_set_sdfgi_frames_to_converge(RenderingServer.ENV_SDFGI_CONVERGE_IN_30_FRAMES)
	RenderingServer.environment_set_sdfgi_frames_to_update_light(RenderingServer.ENV_SDFGI_UPDATE_LIGHT_IN_8_FRAMES)
	RenderingServer.environment_set_sdfgi_ray_count(RenderingServer.ENV_SDFGI_RAY_COUNT_32)
	RenderingServer.environment_glow_set_use_bicubic_upscale(false)
	RenderingServer.gi_set_use_half_resolution(true)


func _configure_viewport() -> void:
	var vp := get_viewport()
	vp.use_debanding = true
	vp.anisotropic_filtering_level = Viewport.ANISOTROPY_16X
	vp.mesh_lod_threshold = 0.5
	if OS.get_name() == "macOS":
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_TEMPORAL
		vp.scaling_3d_scale = SCALE_3D
		vp.texture_mipmap_bias = -0.5
	else:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = 1.0
		vp.use_taa = true


func _disable_msaa() -> void:
	var vp := get_viewport()
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED

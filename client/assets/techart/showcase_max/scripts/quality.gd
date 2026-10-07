extends RefCounted
## Quality profiles and runtime application (no project.godot edits: everything is set by script).

## "shot" = screenshot tier (best this machine renders). "interactive" = tier meant to hold the game-camera frame budget.
static func profile(name: String) -> Dictionary:
	match name:
		"interactive":
			return {
				"profile": "interactive",
				"gi": "sdfgi", "sdfgi_cascades": 3, "sdfgi_cell": 0.6,
				"ssao": true, "ssil": false, "ssr": false,
				"fog": true, "vfog": false, "glow": true,
				"tonemap": "aces", "auto_exposure": false,
				"aa": "metalfx_t", "scale": 0.67,
				"shadow_atlas": 4096, "shadow_mode": "pssm2", "soft_shadow": "medium",
				"sky": "pano_clamped", "omni_budget": 12, "area_lights": false,
			}
		_:
			return {
				"profile": "shot",
				"gi": "voxel", "voxel_subdiv": 512, "sdfgi_cascades": 4, "sdfgi_cell": 0.4,
				"ssao": true, "ssil": true, "ssr": true,
				"fog": true, "vfog": true, "glow": true,
				"tonemap": "aces", "auto_exposure": false,
				"aa": "msaa4_taa", "scale": 1.0,
				"shadow_atlas": 8192, "shadow_mode": "pssm4", "soft_shadow": "ultra",
				"sky": "pano_clamped", "omni_budget": 24, "area_lights": true,
			}

static func parse_overrides(s: String, into: Dictionary) -> void:
	for kv in s.split(",", false):
		var p := kv.split("=")
		if p.size() != 2:
			continue
		var v: Variant = p[1]
		if p[1] == "true":
			v = true
		elif p[1] == "false":
			v = false
		elif p[1].is_valid_float():
			v = float(p[1])
		into[p[0]] = v

static func apply_viewport(sv: SubViewport, fx: Dictionary) -> void:
	sv.msaa_3d = Viewport.MSAA_DISABLED
	sv.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	sv.use_taa = false
	sv.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	sv.scaling_3d_scale = 1.0
	sv.use_debanding = true
	sv.anisotropic_filtering_level = Viewport.ANISOTROPY_16X
	sv.texture_mipmap_bias = 0.0
	sv.mesh_lod_threshold = 0.5
	var aa: String = fx.get("aa", "msaa4_taa")
	var scale := float(fx.get("scale", 1.0))
	match aa:
		"none":
			pass
		"fxaa":
			sv.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		"smaa":
			sv.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
		"taa":
			sv.use_taa = true
		"msaa2":
			sv.msaa_3d = Viewport.MSAA_2X
		"msaa4":
			sv.msaa_3d = Viewport.MSAA_4X
		"msaa8":
			sv.msaa_3d = Viewport.MSAA_8X
		"msaa2_taa":
			sv.msaa_3d = Viewport.MSAA_2X
			sv.use_taa = true
		"msaa4_taa":
			sv.msaa_3d = Viewport.MSAA_4X
			sv.use_taa = true
		"fsr2":
			sv.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
			sv.scaling_3d_scale = scale
			sv.texture_mipmap_bias = -0.5
		"fsr1":
			sv.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
			sv.scaling_3d_scale = scale
		"metalfx_t":
			sv.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_TEMPORAL
			sv.scaling_3d_scale = scale
			sv.texture_mipmap_bias = -0.5
		"metalfx_s":
			sv.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_SPATIAL
			sv.scaling_3d_scale = scale

static func apply_server(fx: Dictionary) -> void:
	var atlas := int(fx.get("shadow_atlas", 8192))
	RenderingServer.directional_shadow_atlas_set_size(atlas, true)
	var q: String = fx.get("soft_shadow", "ultra")
	var qq := RenderingServer.SHADOW_QUALITY_SOFT_ULTRA
	match q:
		"hard": qq = RenderingServer.SHADOW_QUALITY_HARD
		"low": qq = RenderingServer.SHADOW_QUALITY_SOFT_LOW
		"medium": qq = RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM
		"high": qq = RenderingServer.SHADOW_QUALITY_SOFT_HIGH
		_: qq = RenderingServer.SHADOW_QUALITY_SOFT_ULTRA
	RenderingServer.directional_soft_shadow_filter_set_quality(qq)
	RenderingServer.positional_soft_shadow_filter_set_quality(qq)
	var ultra: bool = fx.get("profile", "shot") == "shot"
	RenderingServer.environment_set_ssao_quality(
		RenderingServer.ENV_SSAO_QUALITY_ULTRA if ultra else RenderingServer.ENV_SSAO_QUALITY_MEDIUM,
		true, 0.5, 2.0, 50.0, 300.0)
	RenderingServer.environment_set_ssil_quality(
		RenderingServer.ENV_SSIL_QUALITY_ULTRA if ultra else RenderingServer.ENV_SSIL_QUALITY_MEDIUM,
		true, 0.5, 4.0, 50.0, 300.0)
	RenderingServer.environment_set_sdfgi_frames_to_converge(
		RenderingServer.ENV_SDFGI_CONVERGE_IN_10_FRAMES if ultra else RenderingServer.ENV_SDFGI_CONVERGE_IN_30_FRAMES)
	RenderingServer.environment_set_sdfgi_frames_to_update_light(
		RenderingServer.ENV_SDFGI_UPDATE_LIGHT_IN_1_FRAME if ultra else RenderingServer.ENV_SDFGI_UPDATE_LIGHT_IN_8_FRAMES)
	RenderingServer.environment_set_sdfgi_ray_count(
		RenderingServer.ENV_SDFGI_RAY_COUNT_96 if ultra else RenderingServer.ENV_SDFGI_RAY_COUNT_32)
	RenderingServer.environment_glow_set_use_bicubic_upscale(ultra)
	RenderingServer.camera_attributes_set_dof_blur_quality(
		RenderingServer.DOF_BLUR_QUALITY_HIGH if ultra else RenderingServer.DOF_BLUR_QUALITY_LOW, true)
	RenderingServer.gi_set_use_half_resolution(not ultra)
	RenderingServer.environment_set_volumetric_fog_volume_size(128 if ultra else 64, 128 if ultra else 64)
	RenderingServer.environment_set_volumetric_fog_filter_active(true)

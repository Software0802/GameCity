extends RefCounted
## Feature ablation plan for REPORT.md. Each entry: [group, tag, shot, fx overrides (Dictionary), image mode]
## image mode: "" none, "full" 960x540 downscale, "crop" native-resolution crop of the detail window.
## Timing is draw_ms: 60 force_draw frames after warm-up, GPU queue flushed at the end (1080p unless noted).

static func entries() -> Array:
	var hero := "s01_hero_day"
	var near := "s03_near_block"
	var dusk := "s01_hero_dusk"
	var cine := "s00_cinematic_day"
	var e: Array = []
	# --- baseline tiers
	e.append(["tier", "shot_tier", hero, {}, "full"])
	e.append(["tier", "interactive_tier", hero, {"profile": "interactive"}, "full"])
	# --- global illumination
	e.append(["gi", "none", hero, {"gi": "none"}, "full"])
	e.append(["gi", "sdfgi_4cascade", hero, {"gi": "sdfgi", "sdfgi_cascades": 4}, "full"])
	e.append(["gi", "sdfgi_3cascade", hero, {"gi": "sdfgi", "sdfgi_cascades": 3}, "full"])
	e.append(["gi", "voxel_256", hero, {"gi": "voxel", "voxel_subdiv": 256}, "full"])
	e.append(["gi", "voxel_512", hero, {"gi": "voxel", "voxel_subdiv": 512}, "full"])
	e.append(["gi", "none_near", near, {"gi": "none"}, "full"])
	e.append(["gi", "sdfgi_near", near, {"gi": "sdfgi"}, "full"])
	e.append(["gi", "voxel_512_near", near, {"gi": "voxel", "voxel_subdiv": 512}, "full"])
	# --- screen-space effects, glow, tonemap, exposure
	e.append(["fx", "ssao_off", near, {"ssao": false}, "crop"])
	e.append(["fx", "ssao_on", near, {"ssao": true}, "crop"])
	e.append(["fx", "ssil_off", near, {"ssil": false}, "crop"])
	e.append(["fx", "ssr_off", near, {"ssr": false}, "crop"])
	e.append(["fx", "glow_off", dusk, {"glow": false}, "full"])
	e.append(["fx", "glow_on", dusk, {"glow": true}, "full"])
	e.append(["fx", "tonemap_aces", hero, {"tonemap": "aces"}, "full"])
	e.append(["fx", "tonemap_agx", hero, {"tonemap": "agx"}, "full"])
	e.append(["fx", "tonemap_filmic", hero, {"tonemap": "filmic"}, "full"])
	e.append(["fx", "auto_exposure_on", dusk, {"auto_exposure": true}, "full"])
	e.append(["fx", "auto_exposure_off", dusk, {"auto_exposure": false}, "full"])
	e.append(["fx", "vfog_on", cine, {"vfog": true}, "full"])
	e.append(["fx", "vfog_off", cine, {"vfog": false}, "full"])
	e.append(["fx", "fog_off", cine, {"vfog": false, "fog": false}, "full"])
	# --- glass
	e.append(["glass", "clearcoat_refraction_on", "dev_facade_c", {"clearcoat": true, "refraction": true}, "full"])
	e.append(["glass", "clearcoat_off", "dev_facade_c", {"clearcoat": false, "refraction": true}, "full"])
	e.append(["glass", "refraction_off", "dev_facade_c", {"clearcoat": true, "refraction": false}, "full"])
	e.append(["glass", "both_off", "dev_facade_c", {"clearcoat": false, "refraction": false}, "full"])
	# --- sky
	e.append(["sky", "panorama_clamped", cine, {"sky": "pano_clamped"}, "full"])
	e.append(["sky", "panorama_stock", cine, {"sky": "panorama"}, "full"])
	e.append(["sky", "physical", cine, {"sky": "physical"}, "full"])
	e.append(["sky", "panorama_clamped_dusk", "s00_cinematic_dusk", {"sky": "pano_clamped"}, "full"])
	e.append(["sky", "panorama_stock_dusk", "s00_cinematic_dusk", {"sky": "panorama"}, "full"])
	e.append(["sky", "physical_dusk", "s00_cinematic_dusk", {"sky": "physical"}, "full"])
	# --- anti-aliasing (crop at native resolution)
	for aa in ["none", "fxaa", "smaa", "taa", "msaa2", "msaa4", "msaa4_taa", "msaa8"]:
		e.append(["aa", aa, near, {"aa": aa}, "crop"])
	for aa in ["fsr2", "metalfx_t"]:
		e.append(["aa", aa + "_0.67", near, {"aa": aa, "scale": 0.67}, "crop"])
	# --- shadows
	for a in [2048, 4096, 8192]:
		e.append(["shadow", "atlas_%d" % a, near, {"shadow_atlas": a}, "crop"])
	e.append(["shadow", "mode_pssm4", near, {"shadow_mode": "pssm4"}, "crop"])
	e.append(["shadow", "mode_pssm2", near, {"shadow_mode": "pssm2"}, "crop"])
	e.append(["shadow", "mode_orthogonal", near, {"shadow_mode": "ortho"}, "crop"])
	for q in ["hard", "high", "ultra"]:
		e.append(["shadow", "soft_" + q, near, {"soft_shadow": q}, "crop"])
	e.append(["shadow", "off", hero, {"shadows": false}, ""])
	# --- dusk lights
	for n in [0, 12, 24, 32]:
		e.append(["lights", "omni_%d" % n, dusk, {"omni_budget": n}, ""])
	e.append(["lights", "area_off", "s03_near_block_dusk", {"area_lights": false}, "full"])
	e.append(["lights", "area_on", "s03_near_block_dusk", {"area_lights": true}, "full"])
	e.append(["lights", "area_shadows_on", "s03_near_block_dusk", {"area_lights": true, "area_shadows": true}, "full"])
	# per-shot numbers in both tiers come from tools/perf_shots.sh (one process per shot, TIME_PROCESS + draw_ms)
	return e

extends RefCounted
## Assembles the showcase district: data -> geometry batches -> MeshInstance3D nodes.

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")
const MB := preload("res://client/assets/techart/showcase_max/scripts/mesh_batch.gd")
const Mats := preload("res://client/assets/techart/showcase_max/scripts/mats.gd")
const CityData := preload("res://client/assets/techart/showcase_max/scripts/city_data.gd")
const RoadBuilder := preload("res://client/assets/techart/showcase_max/scripts/road_builder.gd")
const BuildingBuilder := preload("res://client/assets/techart/showcase_max/scripts/building_builder.gd")
const OverlayBuilder := preload("res://client/assets/techart/showcase_max/scripts/overlay_builder.gd")
const TonemapModel := preload("res://client/assets/techart/showcase_max/scripts/tonemap_model.gd")
const PropBuilder := preload("res://client/assets/techart/showcase_max/scripts/prop_builder.gd")

var data
var mats
var root: Node3D
var stats := {}
var building_infos := {}
var overlay_root: Node3D
var props_root: Node3D
var prop_builder
var grid_node: MeshInstance3D
var omni_pool: Array = []

## Keys that should not cast shadows (flat ground layers).
const NO_SHADOW := ["road", "terrain", "sidewalk", "grass", "paving", "gravel", "curb", "path", "water", "fence_mesh", "pool", "lamp",
	"glass_simple", "glass_lobby", "ov_zone", "ov_zone_frame", "ov_bracket", "ov_border", "ov_curtain", "ov_power", "ov_ring", "ov_pulse", "ov_badge", "ov_badge_rim", "ov_grid"]

func build(parent: Node3D) -> void:
	var t0 := Time.get_ticks_msec()
	root = Node3D.new()
	root.name = "District"
	parent.add_child(root)
	mats = Mats.new()
	mats.build()
	data = CityData.new()
	var B := {}
	var rb = RoadBuilder.new(data, B)
	rb.build()
	var bb = BuildingBuilder.new(data, B)
	bb.build()
	building_infos = bb.infos
	area_list = bb.area_lights
	var ob = OverlayBuilder.new(data, B, building_infos)
	ob.build()
	prop_builder = PropBuilder.new(data, B, rb.runs, rb.junctions, building_infos)
	prop_builder.build()
	overlay_root = Node3D.new()
	overlay_root.name = "Overlay"
	root.add_child(overlay_root)
	props_root = Node3D.new()
	props_root.name = "Props"
	root.add_child(props_root)
	_commit(B, root)
	prop_builder.make_instance_nodes(props_root, mats)
	# grid overlay: one big quad, toggled per shot
	var grid := MB.new()
	var g := Cfg.WORLD_HALF + 60.0
	grid.rect_xz(-g, -g, g, g, 0.31, true, 1.0, Color.WHITE)
	var gm := ArrayMesh.new()
	grid.commit(gm, mats.m["ov_grid"])
	grid_node = MeshInstance3D.new()
	grid_node.name = "OverlayGrid"
	grid_node.mesh = gm
	grid_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	grid_node.visible = false
	overlay_root.add_child(grid_node)
	mats.m["ov_grid"].set_shader_parameter("grid_origin", Vector2(-Cfg.WORLD_HALF, -Cfg.WORLD_HALF))
	mats.m["ov_grid"].set_shader_parameter("tile_pitch", Cfg.P)
	# AreaLight3D (new in Godot 4.7) for shopfront / lobby glow at dusk
	if ClassDB.class_exists("AreaLight3D"):
		for i in 10:
			var al: Light3D = ClassDB.instantiate("AreaLight3D")
			al.visible = false
			root.add_child(al)
			area_pool.append(al)
	# lamp light pool (limited OmniLight3D budget, repositioned per shot)
	for i in 32:
		var ol := OmniLight3D.new()
		ol.omni_range = 16.0
		ol.omni_attenuation = 1.4
		ol.light_color = Color(1.0, 0.78, 0.52)
		ol.light_energy = 2.2
		ol.shadow_enabled = false
		ol.visible = false
		root.add_child(ol)
		omni_pool.append(ol)
	stats["build_ms"] = Time.get_ticks_msec() - t0
	print("[showcase] world built in ", stats["build_ms"], " ms: ", data.summary())

func _commit(B: Dictionary, parent: Node3D) -> void:
	var tris := 0
	for full_key in B:
		var batch = B[full_key]
		if batch.is_empty():
			continue
		var key: String = String(full_key).split("|")[0]
		var mesh := ArrayMesh.new()
		var mat: Material = mats.m.get(key)
		if mat == null:
			push_warning("no material for batch " + key)
		batch.commit(mesh, mat)
		if OS.get_environment("CITY_SHOWCASE_DEBUG") == "1":
			print("[batch] ", full_key, " verts=", batch.verts.size(), " tris=", batch.idx.size() / 3, " mat=", mat)
		var mi := MeshInstance3D.new()
		mi.name = "mesh_" + String(full_key).replace("|", "_").replace(",", "_")
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if key in NO_SHADOW else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if key.begins_with("ov_"):
			overlay_root.add_child(mi)
		elif key in ["lamp", "pool", "lamp_pole", "wood", "hedge", "path", "water", "fence_mesh", "container"]:
			props_root.add_child(mi)
		else:
			parent.add_child(mi)
		tris += batch.idx.size() / 3
	stats["tris"] = tris

## Per-shot configuration: grid overlay, lamp lights, area lights.
func apply_palette(tm: Array) -> void:
	# overlay colours are pre-compensated for the preset's ACES + Adjustments so the final image shows the hex values
	var pal := PackedVector3Array()
	pal.resize(16)
	var target: Array = OverlayBuilder.palette()
	var worst := 0.0
	for i in 16:
		var v := Vector3.ONE
		if i < target.size():
			var r: Dictionary = TonemapModel.inverse(target[i], tm[0], tm[1], tm[2], tm[3])
			v = r["lin"]
			worst = maxf(worst, float(r["err"]))
		pal[i] = v
	for sm in mats.overlay_mats:
		sm.set_shader_parameter("pal", pal)
	stats["palette_err"] = worst
	if OS.get_environment("CITY_SHOWCASE_DEBUG") == "1":
		print("[palette] worst residual ", worst, " lin=", pal)

func apply_preset(preset: String, shot: Dictionary, fx: Dictionary, tm := [1.0, 6.0, 1.1, 1.0]) -> void:
	apply_palette(tm)
	var gs: StandardMaterial3D = mats.m["glass_simple"]
	gs.refraction_enabled = bool(fx.get("refraction", true))
	gs.clearcoat_enabled = bool(fx.get("clearcoat", true))
	for k in ["fac_R_brick", "fac_R_plaster", "fac_C_ribbon", "fac_C_curtain", "fac_I"]:
		mats.m[k].set_shader_parameter("use_clearcoat", bool(fx.get("clearcoat", true)))
	var dusk := preset == "dusk"
	grid_node.visible = bool(shot.get("grid", false))
	var budget := int(fx.get("omni_budget", 24)) if dusk else 0
	var focus: Vector3 = shot.get("focus", shot.get("look", Vector3.ZERO))
	var lamps: Array = prop_builder.lamps.duplicate()
	lamps.sort_custom(func(a, b): return Vector2(a["head"].x - focus.x, a["head"].z - focus.z).length_squared() < Vector2(b["head"].x - focus.x, b["head"].z - focus.z).length_squared())
	var area_budget := int(fx.get("area_budget", 8)) if (dusk and bool(fx.get("area_lights", true))) else 0
	var alist: Array = area_list.duplicate()
	alist.sort_custom(func(a, b): return Vector2(a["pos"].x - focus.x, a["pos"].z - focus.z).length_squared() < Vector2(b["pos"].x - focus.x, b["pos"].z - focus.z).length_squared())
	for i in area_pool.size():
		var al: Light3D = area_pool[i]
		if i < mini(area_budget, alist.size()):
			var d: Dictionary = alist[i]
			al.global_position = d["pos"]
			al.look_at(d["pos"] + d["dir"], Vector3.UP)
			al.set("area_size", d["size"])
			al.set("area_range", float(fx.get("area_range", 11.0)))
			al.set("area_normalize_energy", false)
			al.light_color = d["color"]
			al.light_energy = float(d["energy"]) * float(fx.get("area_energy", 0.22))
			al.visible = true
		else:
			al.visible = false
	for i in omni_pool.size():
		var ol: OmniLight3D = omni_pool[i]
		if i < mini(budget, lamps.size()):
			ol.global_position = lamps[i]["head"]
			ol.visible = true
		else:
			ol.visible = false

var voxel_gi: VoxelGI
var voxel_key := ""
var area_pool: Array = []
var area_list: Array = []

## VoxelGI alternative to SDFGI: a baked volume that does not follow the camera.
func setup_voxel_gi(center: Vector3, size: Vector3, subdiv: int, sun: Light3D) -> void:
	if voxel_gi == null:
		voxel_gi = VoxelGI.new()
		voxel_gi.name = "VoxelGI"
		root.add_child(voxel_gi)
	var key := "%s|%s|%d" % [center, size, subdiv]
	if voxel_gi.visible and voxel_key == key:
		return
	voxel_gi.visible = true
	voxel_gi.global_position = center
	voxel_gi.size = size
	match subdiv:
		64: voxel_gi.subdiv = VoxelGI.SUBDIV_64
		128: voxel_gi.subdiv = VoxelGI.SUBDIV_128
		512: voxel_gi.subdiv = VoxelGI.SUBDIV_512
		_: voxel_gi.subdiv = VoxelGI.SUBDIV_256
	sun.light_bake_mode = Light3D.BAKE_DYNAMIC
	var t0 := Time.get_ticks_msec()
	voxel_gi.bake()
	voxel_key = key
	print("[voxelgi] bake subdiv=", subdiv, " size=", size, " took ", Time.get_ticks_msec() - t0, " ms")

func disable_voxel_gi() -> void:
	if voxel_gi != null:
		voxel_gi.visible = false
		voxel_key = ""

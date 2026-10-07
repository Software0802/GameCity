extends RefCounted
## Assembles the showcase district: data -> geometry batches -> MeshInstance3D nodes.

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")
const MB := preload("res://client/assets/techart/showcase_max/scripts/mesh_batch.gd")
const Mats := preload("res://client/assets/techart/showcase_max/scripts/mats.gd")
const CityData := preload("res://client/assets/techart/showcase_max/scripts/city_data.gd")
const RoadBuilder := preload("res://client/assets/techart/showcase_max/scripts/road_builder.gd")
const BuildingBuilder := preload("res://client/assets/techart/showcase_max/scripts/building_builder.gd")
const OverlayBuilder := preload("res://client/assets/techart/showcase_max/scripts/overlay_builder.gd")
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
	"ov_zone", "ov_bracket", "ov_border", "ov_curtain", "ov_power", "ov_ring", "ov_pulse", "ov_badge", "ov_badge_rim", "ov_grid"]

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
func apply_preset(preset: String, shot: Dictionary, fx: Dictionary) -> void:
	var dusk := preset == "dusk"
	grid_node.visible = bool(shot.get("grid", false))
	var budget := int(fx.get("omni_budget", 24)) if dusk else 0
	var focus: Vector3 = shot.get("focus", shot.get("look", Vector3.ZERO))
	var lamps: Array = prop_builder.lamps.duplicate()
	lamps.sort_custom(func(a, b): return Vector2(a["head"].x - focus.x, a["head"].z - focus.z).length_squared() < Vector2(b["head"].x - focus.x, b["head"].z - focus.z).length_squared())
	for i in omni_pool.size():
		var ol: OmniLight3D = omni_pool[i]
		if i < mini(budget, lamps.size()):
			ol.global_position = lamps[i]["head"]
			ol.visible = true
		else:
			ol.visible = false

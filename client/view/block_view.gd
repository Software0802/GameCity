class_name BlockView
extends Node3D

## One 8×8 interest block drawn as flat-color geometry. Each layer is a
## MultiMeshInstance3D with a fixed instance_count; rebuild() only rewrites
## transforms, colors, and visible_instance_count, so a block refresh never
## reallocates. A block the session is not subscribed to collapses to one faint
## quad driven by its RegionSummary.
##
## Layers (y offsets keep the flat quads from fighting):
##   rings      owner color under the tile (neutral: unclaimed)        y 0.01
##   fills      zone color on top (owned bare land: grass)             y 0.03
##   edges      asphalt mixed toward WARN by congestion                 y 0.05
##   power      translucent POWER on covered tiles                      y 0.06
##   brownout   same quad, brighter, toggled by WorldView to flicker    y 0.06
##   pollution  translucent industrial dense color, alpha by pollution  y 0.08
##   buildings  box per building, height by tier (1 / 2 / 3.5)
##   roofs      faction badge on top of each building
##   summary    one faint quad for an unsubscribed block                y 0.005

const BLOCK := SliceConstants.INTEREST_BLOCK
const TILE_COUNT := BLOCK * BLOCK
## Upper bound of edges a block draws: two per tile (its +X and +Y edge).
const EDGE_MAX := TILE_COUNT * 2
const TIER_HEIGHT: Array[float] = [1.0, 2.0, 3.5]
const ALPHA_POWER := 0.30
const ALPHA_BROWNOUT := 0.60
const ALPHA_POLLUTION_MAX := 0.45
const ALPHA_SUMMARY := 0.35
const Y_RING := 0.01
const Y_FILL := 0.03
const Y_EDGE := 0.05
const Y_POWER := 0.06
const Y_POLLUTION := 0.08
## Above the ground plane by more than its own thickness so no face is coplanar with it.
const Y_SUMMARY := 0.02
const POWER_NONE := 0
const POWER_STEADY := 1
const POWER_BROWNOUT := 2

var block: InterestId
## Number of tiles currently in brownout; WorldView flickers blocks where this is > 0.
var brownout_count: int = 0
## How many times rebuild() ran; the view check uses it to prove untouched blocks stay idle.
var rebuild_count: int = 0

var _shared: Dictionary = {}
var _detail_built := false
var _rings: MultiMeshInstance3D
var _fills: MultiMeshInstance3D
var _buildings: MultiMeshInstance3D
var _roofs: MultiMeshInstance3D
var _power: MultiMeshInstance3D
var _brownout: MultiMeshInstance3D
var _pollution: MultiMeshInstance3D
var _edges: MultiMeshInstance3D
var _summary: MultiMeshInstance3D


## shared holds the meshes and materials WorldView builds once:
## lit, overlay (materials); ring, fill, building, roof, edge, overlay_mesh, summary (meshes).
func setup(p_block: InterestId, shared: Dictionary) -> void:
	block = p_block
	_shared = shared
	name = "Block_%d_%d" % [block.block_x, block.block_y]
	_summary = _make_layer("Summary", shared["summary"], shared["overlay"], 1, false)


## Entry point for one block refresh. Reads only the session's view functions.
func rebuild(session: ClientSession) -> void:
	rebuild_count += 1
	var key := block.key()
	if not session.is_subscribed(key):
		_show_summary(session.summary(key))
		return
	_summary.multimesh.visible_instance_count = 0
	_ensure_detail()
	_fill_tiles(session)
	_fill_edges(session)


## WorldView toggles this at the flicker rate; only blocks with brownouts care.
func set_flicker(on: bool) -> void:
	if _brownout != null:
		_brownout.visible = on


func _show_summary(summary: RegionSummary) -> void:
	brownout_count = 0
	if _detail_built:
		for layer in [_rings, _fills, _buildings, _roofs, _power, _brownout, _pollution, _edges]:
			layer.multimesh.visible_instance_count = 0
	var color := Palette.UNCLAIMED
	if summary != null:
		if summary.population > 0:
			color = color.lerp(Palette.GRASS, clampf(summary.population / 16.0, 0.0, 1.0))
		if summary.pollution_avg > 0.0:
			color = color.lerp(Palette.ZONE_I_DENSE, clampf(summary.pollution_avg, 0.0, 1.0) * 0.6)
		if summary.power_alert or summary.brownout:
			color = color.lerp(Palette.WARN, 0.35)
	var center := Vector3(
		(block.block_x + 0.5) * BLOCK, Y_SUMMARY, (block.block_y + 0.5) * BLOCK
	)
	var mm := _summary.multimesh
	mm.set_instance_transform(0, Transform3D(Basis.IDENTITY, center))
	mm.set_instance_color(0, Palette.with_alpha(color, ALPHA_SUMMARY))
	mm.visible_instance_count = 1


func _ensure_detail() -> void:
	if _detail_built:
		return
	_detail_built = true
	_rings = _make_layer("Rings", _shared["ring"], _shared["lit"], TILE_COUNT, false)
	_fills = _make_layer("Fills", _shared["fill"], _shared["lit"], TILE_COUNT, false)
	_edges = _make_layer("Edges", _shared["edge"], _shared["lit"], EDGE_MAX, false)
	_power = _make_layer("Power", _shared["overlay_mesh"], _shared["overlay"], TILE_COUNT, false)
	_brownout = _make_layer("Brownout", _shared["overlay_mesh"], _shared["overlay"], TILE_COUNT, false)
	_pollution = _make_layer("Pollution", _shared["overlay_mesh"], _shared["overlay"], TILE_COUNT, false)
	_buildings = _make_layer("Buildings", _shared["building"], _shared["lit"], TILE_COUNT, true)
	_roofs = _make_layer("Roofs", _shared["roof"], _shared["lit"], TILE_COUNT, false)


func _make_layer(
	layer_name: String, mesh: Mesh, material: Material, count: int, shadows: bool
) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = count
	mm.visible_instance_count = 0
	mm.mesh = mesh
	var node := MultiMeshInstance3D.new()
	node.name = layer_name
	node.multimesh = mm
	node.material_override = material
	if shadows:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	else:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


## Pure mapping from one tile's data to its flat-geometry attributes. rebuild() reads
## it; the headless view check and M4's generator can read it too.
##   ring: owner color under the tile (unclaimed when neutral)
##   fill: zone color, grass for owned bare land, unclaimed when neutral
##   height: building box height by tier, 0.0 when there is no building
##   wall / roof: building box color (dense zone color at the top tier) and faction badge
##   power: POWER_NONE / POWER_STEADY / POWER_BROWNOUT
##   pollution_alpha: 0 when clean
static func tile_style(tile: TileDelta) -> Dictionary:
	var owned := tile.owner != SliceConstants.Owner.NEUTRAL
	var building := tile.has_building and tile.zone != SliceConstants.Zone.NONE
	var tier := clampi(tile.building_tier, 0, TIER_HEIGHT.size() - 1)
	var dense := building and tier >= SliceConstants.BUILDING_TIER_MAX
	var fill := Palette.UNCLAIMED
	if owned:
		fill = Palette.GRASS
		if tile.zone != SliceConstants.Zone.NONE:
			fill = Palette.zone_dense(tile.zone) if dense else Palette.zone(tile.zone)
	var power := POWER_NONE
	if tile.power_covered:
		power = POWER_BROWNOUT if tile.brownout else POWER_STEADY
	var haze := 0.0
	if tile.pollution > 0.01:
		haze = clampf(tile.pollution, 0.0, 1.0) * ALPHA_POLLUTION_MAX
	return {
		"ring": Palette.faction(tile.owner),
		"fill": fill,
		"height": TIER_HEIGHT[tier] if building else 0.0,
		"wall": Palette.zone_dense(tile.zone) if dense else Palette.zone(tile.zone),
		"roof": Palette.faction(tile.owner),
		"power": power,
		"pollution_alpha": haze,
	}


## Asphalt mixed toward WARN by congestion (0–1).
static func edge_color(congestion: float) -> Color:
	return Palette.ASPHALT.lerp(Palette.WARN, clampf(congestion, 0.0, 1.0))


func _fill_tiles(session: ClientSession) -> void:
	var x0 := block.block_x * BLOCK
	var y0 := block.block_y * BLOCK
	var n_building := 0
	var n_power := 0
	var n_brownout := 0
	var n_pollution := 0
	var rings := _rings.multimesh
	var fills := _fills.multimesh
	var buildings := _buildings.multimesh
	var roofs := _roofs.multimesh
	var power := _power.multimesh
	var brownout := _brownout.multimesh
	var pollution := _pollution.multimesh
	var index := 0
	for ty in BLOCK:
		for tx in BLOCK:
			var x := x0 + tx
			var y := y0 + ty
			var style := tile_style(session.view_tile(x, y))
			var cx := x + 0.5
			var cz := y + 0.5

			rings.set_instance_transform(index, Transform3D(Basis.IDENTITY, Vector3(cx, Y_RING, cz)))
			rings.set_instance_color(index, style["ring"])
			fills.set_instance_transform(index, Transform3D(Basis.IDENTITY, Vector3(cx, Y_FILL, cz)))
			fills.set_instance_color(index, style["fill"])
			index += 1

			var height: float = style["height"]
			if height > 0.0:
				var body := Basis.IDENTITY.scaled(Vector3(1.0, height, 1.0))
				buildings.set_instance_transform(n_building, Transform3D(body, Vector3(cx, height * 0.5, cz)))
				buildings.set_instance_color(n_building, style["wall"])
				roofs.set_instance_transform(n_building, Transform3D(Basis.IDENTITY, Vector3(cx, height + 0.03, cz)))
				roofs.set_instance_color(n_building, style["roof"])
				n_building += 1

			var quad := Transform3D(Basis.IDENTITY, Vector3(cx, Y_POWER, cz))
			match int(style["power"]):
				POWER_STEADY:
					power.set_instance_transform(n_power, quad)
					power.set_instance_color(n_power, Palette.with_alpha(Palette.POWER, ALPHA_POWER))
					n_power += 1
				POWER_BROWNOUT:
					brownout.set_instance_transform(n_brownout, quad)
					brownout.set_instance_color(n_brownout, Palette.with_alpha(Palette.POWER, ALPHA_BROWNOUT))
					n_brownout += 1

			var haze: float = style["pollution_alpha"]
			if haze > 0.0:
				pollution.set_instance_transform(n_pollution, Transform3D(Basis.IDENTITY, Vector3(cx, Y_POLLUTION, cz)))
				pollution.set_instance_color(n_pollution, Palette.with_alpha(Palette.ZONE_I_DENSE, haze))
				n_pollution += 1
	rings.visible_instance_count = index
	fills.visible_instance_count = index
	buildings.visible_instance_count = n_building
	roofs.visible_instance_count = n_building
	power.visible_instance_count = n_power
	brownout.visible_instance_count = n_brownout
	pollution.visible_instance_count = n_pollution
	brownout_count = n_brownout


## An edge is drawn by the block holding its ordered first endpoint, or by the
## second endpoint's block when the first one is not subscribed, so a seam edge is
## drawn exactly once.
func _fill_edges(session: ClientSession) -> void:
	var key := block.key()
	var edges := _edges.multimesh
	var n := 0
	for raw in session.view_edges_in_block(key):
		if n >= EDGE_MAX:
			break
		var ordered := WorldState.ordered_edge(raw.a, raw.b)
		var key_a := InterestId.from_tile(ordered.a.x, ordered.a.y).key()
		var mine := key_a == key or not session.is_subscribed(key_a)
		if not mine:
			continue
		var color := edge_color(raw.congestion)
		var transform: Transform3D
		if ordered.a.y == ordered.b.y:
			transform = Transform3D(Basis.IDENTITY, Vector3(ordered.a.x + 1.0, Y_EDGE, ordered.a.y + 0.5))
		else:
			var turned := Basis.IDENTITY.rotated(Vector3.UP, PI * 0.5)
			transform = Transform3D(turned, Vector3(ordered.a.x + 0.5, Y_EDGE, ordered.a.y + 1.0))
		edges.set_instance_transform(n, transform)
		edges.set_instance_color(n, color)
		n += 1
	edges.visible_instance_count = n

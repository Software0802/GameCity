class_name BlockView
extends Node3D

## One 8×8 interest block drawn with the live pack (client/assets/techart/live): the showcase
## procedural mid-realism (roads with curbs and lane paint, R / C / I facades by tier, lot pads,
## props) plus the palette overlay (owner outline, zone frame, power, congestion pulse,
## pollution haze, roof badges). A block the session is not subscribed to collapses to one faint
## summary quad driven by its RegionSummary.
##
## Data path: snapshot(session) reads only ClientSession.is_subscribed / view_tile /
## view_edges_in_block / summary; build() turns the snapshot (plus the orthogonal neighbours'
## snapshots for the seam ring) into geometry. Layers are MeshInstance3D nodes whose mesh is
## replaced on rebuild (nodes are reused):
##   Roads      carriageways, sidewalks, curbs                  no shadows
##   Pads       raised lot pads (grass / paving / gravel)       no shadows
##   Lots       buildings and lot props (fences, hedges ...)    shadows
##   Street     lamp posts along the roads                      shadows
##   Overlay    palette overlay (unshaded, transparent)
##   Brownout   brownout power fill, toggled by WorldView's flicker
##   Summary    one quad for an unsubscribed block
##   Trees*/Bushes/Cars*  MultiMesh instances
## Each layer keeps a signature of the inputs it depends on and is only regenerated when that
## changes. Per tile, the building, its lot props and its overlay pieces are cached by the
## tile fields they depend on, so a one-tile change costs one building plus a merge.

const Cfg := preload("res://client/assets/techart/live/scripts/live_cfg.gd")
const LB := preload("res://client/assets/techart/live/scripts/live_batch.gd")
const Data := preload("res://client/assets/techart/live/scripts/block_city_data.gd")
const Roads := preload("res://client/assets/techart/live/scripts/live_roads.gd")
const Buildings := preload("res://client/assets/techart/live/scripts/live_buildings.gd")
const Overlay := preload("res://client/assets/techart/live/scripts/live_overlay.gd")
const Props := preload("res://client/assets/techart/live/scripts/live_props.gd")
const Pal := preload("res://client/assets/techart/live/scripts/live_palette.gd")

const BLOCK := SliceConstants.INTEREST_BLOCK
const TILE_COUNT := BLOCK * BLOCK
## Nominal roof height per tier in metres (midpoint of the live builder's ranges), for the
## pure style mapping below; the generated buildings vary around these.
const TIER_HEIGHT: Array[float] = [8.0, 18.0, 45.0]
const ALPHA_POLLUTION_MAX := Overlay.ALPHA_HAZE_MAX
const POWER_NONE := 0
const POWER_STEADY := 1
const POWER_BROWNOUT := 2
const SUMMARY_ALPHA := 0.35
const SUMMARY_Y := 0.1
## Window state written into the facade COLOR alpha (see facade_live.gdshader).
const WINDOW_BROWNOUT := 0.0
const WINDOW_UNPOWERED := 0.08
const WINDOW_MIN := 0.2
const ORTHOGONAL: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const ROAD_KEYS := ["road", "sidewalk", "curb"]
const PAD_KEYS := ["grass", "paving", "gravel"]

var block: InterestId
## Number of tiles currently in brownout; WorldView flickers blocks where this is > 0.
var brownout_count: int = 0
## How many times rebuild() ran (WorldView counts its dirty passes here too); the view check
## uses it to prove untouched blocks stay idle.
var rebuild_count: int = 0
## How many times any layer's geometry was regenerated (ring refreshes count only when they
## changed something).
var geometry_builds: int = 0
## Wall-clock cost of the last build() in milliseconds.
var last_build_ms: float = 0.0
## Counters and layer timings of the last detailed build (view check and perf log).
var stats: Dictionary = {}

## Snapshot of the session for this block.
var subscribed: bool = false
var tiles: Array = []
var edges: Dictionary = {}
var summary: RegionSummary = null
## Signature of what the neighbours read from this block (border tile owners, edges touching
## the block's outer tiles, subscription); WorldView refreshes the neighbours when it changes.
var seam_signature: String = ""

var _shared: Dictionary = {}
var _blocks: Dictionary = {}
var _subs: Dictionary = {}
var _detail_built := false
var _roads: MeshInstance3D
var _pads: MeshInstance3D
var _lots: MeshInstance3D
var _street: MeshInstance3D
var _overlay: MeshInstance3D
var _brownout: MeshInstance3D
var _summary: MultiMeshInstance3D
var _mmi: Dictionary = {}
var _tile_cache: Array = []
var _sig_roads := ""
var _sig_pads := ""
var _sig_lots := ""
var _sig_overlay := ""
var _sig_street := ""
var _road_runs: Array = []
var _junction_cache: Dictionary = {}
var _run_cache: Dictionary = {}
var _infos: Dictionary = {}
var _lot_inst: Dictionary = Props.empty_instances()
var _street_inst: Dictionary = {}
## Edge keys / corners drawn by this block's last ground build (seam checks).
var segments_drawn: Array[String] = []
var corners_drawn: Array[Vector2i] = []


## shared comes from WorldView._build_shared: mats, pal (PackedVector3Array), quad (unit quad
## mesh), tree_meshes, car_meshes, blocks (the WorldView block dictionary).
func setup(p_block: InterestId, shared: Dictionary) -> void:
	block = p_block
	_shared = shared
	_blocks = shared["blocks"]
	name = "Block_%d_%d" % [block.block_x, block.block_y]
	_tile_cache.resize(TILE_COUNT)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = 1
	mm.visible_instance_count = 0
	mm.mesh = shared["quad"]
	_summary = MultiMeshInstance3D.new()
	_summary.name = "Summary"
	_summary.multimesh = mm
	_summary.material_override = shared["mats"].m["ov_direct"]
	_summary.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_summary)


## Entry point for one block refresh (snapshot + build). Reads only the session's view functions.
func rebuild(session: ClientSession) -> void:
	rebuild_count += 1
	snapshot(session)
	build()


## Phase 1: copy what this block needs from the session.
func snapshot(session: ClientSession) -> void:
	var key := block.key()
	subscribed = session.is_subscribed(key)
	summary = session.summary(key)
	var x0 := block.block_x * BLOCK
	var y0 := block.block_y * BLOCK
	tiles.resize(TILE_COUNT)
	for ty in BLOCK:
		for tx in BLOCK:
			tiles[ty * BLOCK + tx] = session.view_tile(x0 + tx, y0 + ty)
	edges.clear()
	for raw in session.view_edges_in_block(key):
		edges[WorldState.edge_key(raw.a, raw.b)] = raw
	_subs.clear()
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var nx := block.block_x + dx
			var ny := block.block_y + dy
			if nx < 0 or ny < 0 or nx >= SliceConstants.BLOCKS_PER_AXIS or ny >= SliceConstants.BLOCKS_PER_AXIS:
				continue
			var nkey := "%d,%d" % [nx, ny]
			_subs[nkey] = session.is_subscribed(nkey)
	seam_signature = _seam_signature(x0, y0)


func _seam_signature(x0: int, y0: int) -> String:
	var parts := PackedStringArray()
	parts.append("+" if subscribed else "-")
	for ty in BLOCK:
		for tx in BLOCK:
			if tx == 0 or ty == 0 or tx == BLOCK - 1 or ty == BLOCK - 1:
				parts.append(str(tiles[ty * BLOCK + tx].owner))
	var keys := PackedStringArray()
	for key in edges:
		var e: EdgeDelta = edges[key]
		var ax := e.a.x - x0
		var ay := e.a.y - y0
		var bx := e.b.x - x0
		var by := e.b.y - y0
		var outer := ax <= 0 or ay <= 0 or ax >= BLOCK - 1 or ay >= BLOCK - 1 or bx <= 0 or by <= 0 or bx >= BLOCK - 1 or by >= BLOCK - 1
		if outer:
			keys.append(key)
	keys.sort()
	parts.append_array(keys)
	return ",".join(parts)


## Phase 2: regenerate the layers whose inputs changed since the last build.
func build() -> void:
	var t0 := Time.get_ticks_usec()
	if not subscribed:
		_show_summary()
	else:
		_build_detail()
	last_build_ms = (Time.get_ticks_usec() - t0) / 1000.0


## WorldView toggles this at the flicker rate; only blocks with brownouts care.
func set_flicker(on: bool) -> void:
	if _brownout != null:
		_brownout.visible = on


## Forget cached buildings and layer signatures so the next build() regenerates everything
## (memory release, and the view check's cold-build timing).
func reset_geometry() -> void:
	_tile_cache.fill(null)
	_junction_cache.clear()
	_run_cache.clear()
	_sig_roads = ""
	_sig_pads = ""
	_sig_lots = ""
	_sig_overlay = ""
	_sig_street = ""


func _show_summary() -> void:
	brownout_count = 0
	if _detail_built:
		var changed := _sig_roads != "" or _sig_pads != "" or _sig_lots != "" or _sig_overlay != "" or _sig_street != ""
		for node in [_roads, _pads, _lots, _street, _overlay, _brownout]:
			node.mesh = null
		for mname in _mmi:
			_mmi[mname].multimesh.instance_count = 0
			_mmi[mname].visible = false
		reset_geometry()
		_junction_cache.clear()
		_run_cache.clear()
		_road_runs = []
		_infos = {}
		_lot_inst = Props.empty_instances()
		_street_inst = {}
		segments_drawn = []
		corners_drawn = []
		stats = {}
		if changed:
			geometry_builds += 1
	var pal: PackedVector3Array = _shared["pal"]
	var lin: Vector3 = pal[Pal.SLOT_UNCLAIMED]
	if summary != null:
		if summary.population > 0:
			lin = lin.lerp(pal[Pal.SLOT_GRASS], clampf(summary.population / 16.0, 0.0, 1.0))
		if summary.pollution_avg > 0.0:
			lin = lin.lerp(pal[Pal.SLOT_I_DENSE], clampf(summary.pollution_avg, 0.0, 1.0) * 0.6)
		if summary.power_alert or summary.brownout:
			lin = lin.lerp(pal[Pal.SLOT_WARN], 0.35)
	var size := BLOCK * Cfg.P
	var center := Vector3((block.block_x + 0.5) * size, SUMMARY_Y, (block.block_y + 0.5) * size)
	var mm := _summary.multimesh
	mm.set_instance_transform(0, Transform3D(Basis.IDENTITY.scaled(Vector3(size - 2.0, 1.0, size - 2.0)), center))
	# overlay mode 6 multiplies COLOR.rgb by 2 (8-bit vertex colours cannot hold linear values above 1)
	mm.set_instance_color(0, Color(lin.x * 0.5, lin.y * 0.5, lin.z * 0.5, SUMMARY_ALPHA))
	mm.visible_instance_count = 1


func _ensure_detail() -> void:
	if _detail_built:
		return
	_detail_built = true
	_roads = _make_layer("Roads", false)
	_pads = _make_layer("Pads", false)
	_lots = _make_layer("Lots", true)
	_street = _make_layer("Street", true)
	_overlay = _make_layer("Overlay", false)
	_brownout = _make_layer("Brownout", false)


func _make_layer(layer_name: String, shadows: bool) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = layer_name
	if shadows:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	else:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


## Pure mapping from one tile's data to its semantic view attributes. The headless view check
## reads it; the live builders derive geometry from the same fields.
##   ring: owner color (unclaimed when neutral)
##   fill: zone color, grass for owned bare land, unclaimed when neutral
##   height: nominal roof height by tier in metres, 0.0 when there is no building
##   wall / roof: zone color (dense at the top tier) and faction badge color
##   power: POWER_NONE / POWER_STEADY / POWER_BROWNOUT
##   pollution_alpha: 0 when clean
##   window: facade window state (WINDOW_BROWNOUT / WINDOW_UNPOWERED / brightness)
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
		"window": window_state(tile),
	}


## Facade window state: dark when unpowered, flickering when in brownout, brighter with satisfaction.
static func window_state(tile: TileDelta) -> float:
	if tile.power_covered and tile.brownout:
		return WINDOW_BROWNOUT
	if not tile.power_covered:
		return WINDOW_UNPOWERED
	return WINDOW_MIN + (1.0 - WINDOW_MIN) * clampf(tile.satisfaction, 0.0, 1.0)


## Asphalt mixed toward WARN by congestion (0–1); the HUD and the pulse strength use the same ramp.
static func edge_color(congestion: float) -> Color:
	return Palette.ASPHALT.lerp(Palette.WARN, clampf(congestion, 0.0, 1.0))


# ---------------------------------------------------------------- detail build

func _build_detail() -> void:
	_ensure_detail()
	_summary.multimesh.visible_instance_count = 0
	var t0 := Time.get_ticks_usec()
	var data := _make_data()
	var road_masks := PackedInt32Array()
	var free_masks := PackedInt32Array()
	var lot_keys := PackedStringArray()
	var pad_keys := PackedStringArray()
	var states := PackedStringArray()
	for t in tiles:
		var roads := data.tile_roads(t.x, t.y)
		var free := Roads.corners_free(data, t.x, t.y)
		road_masks.append(roads)
		free_masks.append(free)
		lot_keys.append(_lot_key(t, roads))
		pad_keys.append(_pad_key(t, roads, free))
		states.append(str(roundi(window_state(t) * 100.0)))
	var sig_roads := _roads_signature(data)
	var sig_pads := ",".join(pad_keys)
	var sig_lots := ",".join(lot_keys) + "#" + ",".join(states)
	var sig_overlay := _overlay_signature(data, lot_keys)
	stats["ms_sig"] = (Time.get_ticks_usec() - t0) / 1000.0
	var changed := false
	var instances_dirty := false
	if sig_roads != _sig_roads:
		t0 = Time.get_ticks_usec()
		_build_roads(data)
		stats["ms_roads"] = (Time.get_ticks_usec() - t0) / 1000.0
		_sig_roads = sig_roads
		changed = true
	if sig_pads != _sig_pads:
		t0 = Time.get_ticks_usec()
		_build_pads(pad_keys, road_masks, free_masks)
		stats["ms_pads"] = (Time.get_ticks_usec() - t0) / 1000.0
		_sig_pads = sig_pads
		changed = true
	if sig_lots != _sig_lots:
		t0 = Time.get_ticks_usec()
		_build_lots(data, lot_keys)
		stats["ms_lots"] = (Time.get_ticks_usec() - t0) / 1000.0
		_sig_lots = sig_lots
		changed = true
		instances_dirty = true
	if sig_overlay != _sig_overlay:
		t0 = Time.get_ticks_usec()
		_build_overlay(data, lot_keys)
		stats["ms_overlay"] = (Time.get_ticks_usec() - t0) / 1000.0
		_sig_overlay = sig_overlay
		changed = true
	if sig_roads != _sig_street:
		t0 = Time.get_ticks_usec()
		_build_street()
		stats["ms_street"] = (Time.get_ticks_usec() - t0) / 1000.0
		_sig_street = sig_roads
		changed = true
		instances_dirty = true
	if instances_dirty:
		t0 = Time.get_ticks_usec()
		_refresh_instances()
		stats["ms_instances"] = (Time.get_ticks_usec() - t0) / 1000.0
	if changed:
		geometry_builds += 1


func _make_data() -> Data:
	var data := Data.new()
	data.setup(block.block_x, block.block_y)
	data.tiles = tiles
	data.subscribed = _subs
	for key in edges:
		data.edges[key] = edges[key]
	for step in ORTHOGONAL:
		var nx := block.block_x + step.x
		var ny := block.block_y + step.y
		var nb: BlockView = _blocks.get("%d,%d" % [nx, ny])
		if nb == null or nb.tiles.is_empty():
			continue
		for key in nb.edges:
			var e: EdgeDelta = nb.edges[key]
			if _touches_window(data, e.a) and _touches_window(data, e.b):
				data.edges[key] = e
		# the neighbour's row or column that borders this block
		for k in BLOCK:
			var t: TileDelta
			if step.x == 1:
				t = nb.tiles[k * BLOCK]
			elif step.x == -1:
				t = nb.tiles[k * BLOCK + BLOCK - 1]
			elif step.y == 1:
				t = nb.tiles[k]
			else:
				t = nb.tiles[(BLOCK - 1) * BLOCK + k]
			data.ring[t.id] = t
	data.index_edges()
	return data


static func _touches_window(data: Data, p: Vector2i) -> bool:
	return p.x >= data.x0 - 1 and p.y >= data.y0 - 1 and p.x <= data.x0 + BLOCK and p.y <= data.y0 + BLOCK


## Everything the building and the lot props of a tile depend on.
static func _lot_key(t: TileDelta, roads: int) -> String:
	return "%d/%d/%d/%d/%d" % [1 if t.owner != SliceConstants.Owner.NEUTRAL else 0, t.zone,
		clampi(t.building_tier, SliceConstants.BUILDING_TIER_MIN, SliceConstants.BUILDING_TIER_MAX), 1 if t.has_building else 0, roads]


## Everything the lot pad of a tile depends on.
static func _pad_key(t: TileDelta, roads: int, free: int) -> String:
	if t.owner == SliceConstants.Owner.NEUTRAL:
		return "-"
	return "%s/%d/%d" % [Roads.pad_key(t.zone), roads, free]


## Roads depend on the window's edges and on which blocks are subscribed (seam ownership).
func _roads_signature(data: Data) -> String:
	var parts := PackedStringArray()
	var keys := data.edges.keys()
	keys.sort()
	parts.append_array(PackedStringArray(keys))
	parts.append("|")
	for k in data.subscribed:
		parts.append(k + ("+" if data.subscribed[k] else "-"))
	return "".join(parts)


## Per-tile overlay keys plus the block-level inputs (edge congestion, ring owners for the
## territory border, ownership of seam edges through the subscription flags).
func _overlay_signature(data: Data, lot_keys: PackedStringArray) -> String:
	var parts := PackedStringArray()
	for i in TILE_COUNT:
		var t: TileDelta = tiles[i]
		parts.append(Overlay.tile_key(t, t.has_building) + "|" + lot_keys[i])
	for key in data.edges:
		var e: EdgeDelta = data.edges[key]
		if e.congestion >= Overlay.PULSE_MIN:
			parts.append("%s=%d" % [key, roundi(e.congestion * 32.0)])
	for id in data.ring:
		parts.append("r%d:%d" % [id, data.ring[id].owner])
	for k in data.subscribed:
		parts.append(k + ("+" if data.subscribed[k] else "-"))
	return ",".join(parts)


func _build_roads(data: Data) -> void:
	var batches := {}
	var roads = Roads.new(data, batches, _junction_cache)
	roads.build()
	_road_runs = roads.runs
	segments_drawn = roads.segments_drawn
	corners_drawn = roads.corners_drawn
	_commit(batches, _roads, ROAD_KEYS)
	stats["segments"] = segments_drawn.size()
	stats["corners"] = corners_drawn.size()
	stats["runs"] = _road_runs.size()


static func _new_entry() -> Dictionary:
	return {"key": "", "batches": {}, "info": {}, "inst": Props.empty_instances(), "ov_key": "", "ov": {}, "pad_key": "", "pad": {},
		"fac_alpha": -1.0, "fac_cols": {}}


## Lot pads: per-tile cache keyed by _pad_key, merged per material.
func _build_pads(pad_keys: PackedStringArray, road_masks: PackedInt32Array, free_masks: PackedInt32Array) -> void:
	var merged := {}
	for idx in TILE_COUNT:
		var key := pad_keys[idx]
		if key == "-":
			continue
		var entry = _tile_cache[idx]
		if entry == null:
			entry = _new_entry()
			_tile_cache[idx] = entry
		if entry["pad_key"] != key:
			var pad := {}
			Roads.tile_pad(tiles[idx], road_masks[idx], free_masks[idx], pad)
			entry["pad"] = pad
			entry["pad_key"] = key
		var pad: Dictionary = entry["pad"]
		for k in pad:
			var dst = merged.get(k)
			if dst == null:
				dst = LB.new()
				merged[k] = dst
			dst.append(pad[k])
	_commit(merged, _pads, PAD_KEYS)


## Buildings and lot props: per-tile cache keyed by _lot_key, merged into one mesh.
func _build_lots(data: Data, lot_keys: PackedStringArray) -> void:
	var builder = Buildings.new(data)
	var props = Props.new()
	var merged := {}
	var kinds := {}
	var count := 0
	var generated := 0
	_infos = {}
	_lot_inst = Props.empty_instances()
	for idx in TILE_COUNT:
		var t: TileDelta = tiles[idx]
		var key := lot_keys[idx]
		var entry = _tile_cache[idx]
		if entry == null:
			entry = _new_entry()
			_tile_cache[idx] = entry
		if entry["key"] != key:
			var roads := data.tile_roads(t.x, t.y)
			var desc := Buildings.descriptor(t, roads)
			var result: Dictionary = builder.build_tile(desc)
			var batches: Dictionary = result.get("batches", {})
			var info: Dictionary = result.get("info", {})
			var inst: Dictionary = props.lot(t, roads, info, batches)
			entry["key"] = key
			entry["batches"] = batches
			entry["info"] = info
			entry["inst"] = inst
			entry["fac_alpha"] = -1.0
			generated += 1
		var info: Dictionary = entry["info"]
		if not info.is_empty():
			count += 1
			_infos[t.id] = info
			kinds[info["kind"]] = int(kinds.get(info["kind"], 0)) + 1
		var alpha := window_state(t)
		var batches: Dictionary = entry["batches"]
		# facade colours with the window state alpha, cached until the state changes
		if not is_equal_approx(float(entry.get("fac_alpha", -1.0)), alpha):
			var patched := {}
			for k in batches:
				if String(k).begins_with("fac_"):
					patched[k] = LB.colors_with_alpha(batches[k], alpha)
			entry["fac_alpha"] = alpha
			entry["fac_cols"] = patched
		var fac_cols: Dictionary = entry["fac_cols"]
		for k in batches:
			var dst = merged.get(k)
			if dst == null:
				dst = LB.new()
				dst.use_custom0 = String(k).begins_with("fac_")
				merged[k] = dst
			if dst.use_custom0:
				dst.append_with_colors(batches[k], fac_cols[k])
			else:
				dst.append(batches[k])
		var inst: Dictionary = entry["inst"]
		for v in Props.TREE_VARIANTS:
			_lot_inst["trees"][v].append_array(inst["trees"][v])
			_lot_inst["tree_cols"][v].append_array(inst["tree_cols"][v])
		_lot_inst["bushes"].append_array(inst["bushes"])
		_lot_inst["bush_cols"].append_array(inst["bush_cols"])
	_commit(merged, _lots, [])
	stats["buildings"] = count
	stats["generated"] = generated
	stats["kinds"] = kinds


func _build_overlay(data: Data, lot_keys: PackedStringArray) -> void:
	var merged := {}
	var power := 0
	var brownout := 0
	var haze := 0
	var badges := 0
	for idx in TILE_COUNT:
		var t: TileDelta = tiles[idx]
		var entry = _tile_cache[idx]
		if entry == null:
			continue
		var info: Dictionary = entry["info"]
		var ov_key := Overlay.tile_key(t, not info.is_empty()) + "|" + lot_keys[idx]
		if entry["ov_key"] != ov_key:
			entry["ov"] = Overlay.tile_pieces(t, info)
			entry["ov_key"] = ov_key
		var pieces: Dictionary = entry["ov"]
		for k in pieces:
			var dst = merged.get(k)
			if dst == null:
				dst = LB.new()
				merged[k] = dst
			dst.append(pieces[k])
		if t.power_covered:
			if t.brownout:
				brownout += 1
			else:
				power += 1
		if t.pollution > 0.01:
			haze += 1
		if t.owner != SliceConstants.Owner.NEUTRAL and t.has_building and not info.is_empty():
			badges += 1
	var ov = Overlay.new(data, merged)
	ov.build()
	var brown: Dictionary = {}
	if merged.has("ov_brownout"):
		brown["ov_field"] = merged["ov_brownout"]
		merged.erase("ov_brownout")
	_commit(merged, _overlay, [])
	_commit(brown, _brownout, [])
	brownout_count = brownout
	stats["power"] = power
	stats["brownout"] = brownout
	stats["haze"] = haze
	stats["badges"] = badges
	stats["pulses"] = ov.pulse_edges
	stats["borders"] = ov.border_pieces


func _build_street() -> void:
	var batches := {}
	var props = Props.new()
	props.build_street(_road_runs, batches, _run_cache)
	_commit(batches, _street, [])
	_street_inst = {
		"trees": props.tree_inst, "tree_cols": props.tree_col,
		"cars": props.car_inst, "car_cols": props.car_col,
	}
	stats["lamps"] = props.lamp_count


## Trees, bushes and cars from the lot cache and the street pass into the MultiMesh nodes.
func _refresh_instances() -> void:
	var tree_meshes: Array = _shared["tree_meshes"]
	var car_meshes: Array = _shared["car_meshes"]
	var trees := 0
	for v in Props.TREE_VARIANTS:
		var xfs: Array = _lot_inst["trees"][v].duplicate()
		var cols: Array = _lot_inst["tree_cols"][v].duplicate()
		if _street_inst.has("trees"):
			xfs.append_array(_street_inst["trees"][v])
			cols.append_array(_street_inst["tree_cols"][v])
		trees += xfs.size()
		_set_instances("Trees%d" % v, tree_meshes[v], xfs, cols)
	_set_instances("Bushes", tree_meshes[Props.TREE_VARIANTS], _lot_inst["bushes"], _lot_inst["bush_cols"])
	var cars := 0
	for v in Props.CAR_KITS.size():
		var xfs: Array = _street_inst["cars"][v] if _street_inst.has("cars") else []
		var cols: Array = _street_inst["car_cols"][v] if _street_inst.has("cars") else []
		cars += xfs.size()
		_set_instances("Cars%d" % v, car_meshes[v], xfs, cols)
	stats["trees"] = trees
	stats["bushes"] = _lot_inst["bushes"].size()
	stats["cars"] = cars


## Replace a layer's mesh with the committed batches (sorted keys, one surface per material).
## `only` restricts the keys; others are dropped with a warning.
func _commit(batches: Dictionary, node: MeshInstance3D, only: Array) -> void:
	var mats: Dictionary = _shared["mats"].m
	var keys := batches.keys()
	keys.sort()
	var mesh: ArrayMesh = null
	for key in keys:
		var batch = batches[key]
		if batch.is_empty():
			continue
		if not only.is_empty() and not only.has(key):
			push_warning("block %s: batch %s has no layer" % [block.key(), key])
			continue
		var mat: Material = mats.get(key)
		if mat == null:
			push_warning("block %s: no material for batch %s" % [block.key(), key])
		if mesh == null:
			mesh = ArrayMesh.new()
		batch.commit(mesh, mat)
	node.mesh = mesh


func _set_instances(mname: String, mesh: Mesh, xfs: Array, cols: Array) -> void:
	var mmi: MultiMeshInstance3D = _mmi.get(mname)
	if mmi == null:
		if xfs.is_empty():
			return
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mmi = MultiMeshInstance3D.new()
		mmi.name = mname
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(mmi)
		_mmi[mname] = mmi
	var mm := mmi.multimesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
		mm.set_instance_color(i, cols[i])
	mmi.visible = not xfs.is_empty()

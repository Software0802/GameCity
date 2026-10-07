extends Node3D

## Headless check of the per-block live view: feeds a WorldView through a ClientSession and
## asserts that only dirty blocks are rebuilt, that the live layers carry the expected content
## (buildings per zone and tier, road segments and junctions, power / brownout / haze overlays),
## that a seam edge and a seam junction are drawn by exactly one block and hand over on
## subscription changes, that a neighbour refreshes its seam when an edge appears next to it,
## that rebuild costs stay inside the M4 budget (one block <= 8 ms, 256 blocks <= 2 s), and
## that the camera's tile <-> screen mapping round-trips in metres. Prints VIEW_OK and exits 0.
##   godot --headless --path . res://client/dev/view_check.tscn

const BUDGET_BLOCK_MS := 8.0
const BUDGET_ALL_MS := 2000.0

var _failures: Array[String] = []
var session: ClientSession
var view: WorldView
var camera: CameraRig


func _ready() -> void:
	session = ClientSession.new()
	session.name = "Session"
	add_child(session)
	view = WorldView.new()
	view.name = "World"
	add_child(view)
	camera = CameraRig.new()
	camera.name = "Camera"
	add_child(camera)
	view.bind(session)
	_run()
	if _failures.is_empty():
		print("VIEW_OK")
		get_tree().quit(0)
	else:
		for line in _failures:
			printerr("VIEW_FAIL " + line)
		get_tree().quit(1)


func _run() -> void:
	var welcome := ServerWelcome.new()
	welcome.faction = SliceConstants.Owner.FACTION_A
	_emit(ServerEvent.with_welcome(welcome))
	_emit(ServerEvent.with_match_start(MatchStart.new()))

	# Every block is unsubscribed: one summary quad each, no detail layers.
	var far := view.block_view("9,9")
	_expect(far != null, "block 9,9 exists")
	_expect(_summary_visible(far) == 1, "unsubscribed block shows its summary quad")
	_expect(far.get_node_or_null("Roads") == null, "unsubscribed block has no detail layers")
	_expect(view.detailed_block_count() == 0, "no detailed blocks before any subscription")

	# Subscribe block 0,0 and feed a few tiles and edges.
	var update := InterestUpdate.new()
	update.add.append(InterestId.new(0, 0))
	_emit(ServerEvent.with_interest_update(update))
	var owned := TileDelta.from_cell(1, 1)
	owned.owner = SliceConstants.Owner.FACTION_A
	owned.zone = SliceConstants.Zone.R
	owned.has_building = true
	owned.building_tier = 2
	owned.power_covered = true
	owned.satisfaction = 0.5
	_emit(ServerEvent.with_tile_delta(owned))
	var dim := TileDelta.from_cell(2, 1)
	dim.owner = SliceConstants.Owner.FACTION_A
	dim.zone = SliceConstants.Zone.C
	dim.has_building = true
	dim.power_covered = true
	dim.brownout = true
	dim.pollution = 0.5
	_emit(ServerEvent.with_tile_delta(dim))
	var road := WorldState.ordered_edge(Vector2i(1, 1), Vector2i(2, 1))
	road.congestion = 0.9
	_emit(ServerEvent.with_edge_delta(road))
	var seam := WorldState.ordered_edge(Vector2i(7, 3), Vector2i(8, 3))
	_emit(ServerEvent.with_edge_delta(seam))
	var seam_key := WorldState.edge_key(Vector2i(7, 3), Vector2i(8, 3))

	var near := view.block_view("0,0")
	_expect(_summary_visible(near) == 0, "subscribed block hides its summary quad")
	_expect(_mesh(near, "Roads") != null and _mesh(near, "Lots") != null and _mesh(near, "Overlay") != null, "subscribed block has ground, building and overlay meshes")
	_expect(int(near.stats.get("buildings", -1)) == 2, "two buildings (got %s)" % str(near.stats.get("buildings")))
	var kinds: Dictionary = near.stats.get("kinds", {})
	_expect(kinds.has("R2") and kinds.has("C0"), "an R tier-2 and a C tier-0 building were generated (got %s)" % str(kinds))
	_expect(int(near.stats.get("badges", -1)) == 2, "two roof badges")
	_expect(int(near.stats.get("power", -1)) == 1, "one steady power field (got %s)" % str(near.stats.get("power")))
	_expect(int(near.stats.get("brownout", -1)) == 1, "one brownout field")
	_expect(near.brownout_count == 1 and _mesh(near, "Brownout") != null, "brownout_count feeds the flicker and the brownout layer has a mesh")
	_expect(int(near.stats.get("haze", -1)) == 1, "one pollution haze")
	_expect(int(near.stats.get("pulses", -1)) == 1, "one congestion pulse for the 0.9 edge (got %s)" % str(near.stats.get("pulses")))
	_expect(int(near.stats.get("segments", -1)) == 2, "inner edge and seam edge drawn by block 0,0 (got %s)" % str(near.stats.get("segments")))
	_expect(int(near.stats.get("corners", -1)) == 4, "two dead-end junctions per edge, all owned by block 0,0 (got %s)" % str(near.stats.get("corners")))
	_expect(near.segments_drawn.has(seam_key), "block 0,0 drew the seam segment")
	var neighbour := view.block_view("1,0")
	_expect(neighbour.get_node_or_null("Roads") == null, "unsubscribed neighbour draws nothing")

	# Pure style mapping: nominal tier heights (metres), dense color, badge, window state, edge mix.
	var tall := BlockView.tile_style(session.view_tile(1, 1))
	_expect(is_equal_approx(tall["height"], BlockView.TIER_HEIGHT[2]), "tier 2 nominal height is %.0f m (got %.2f)" % [BlockView.TIER_HEIGHT[2], tall["height"]])
	_expect(tall["wall"].is_equal_approx(Palette.ZONE_R_DENSE), "tier 2 R uses the dense R color")
	_expect(tall["fill"].is_equal_approx(Palette.ZONE_R_DENSE), "tier 2 R lot fill uses the dense R color")
	_expect(tall["roof"].is_equal_approx(Palette.FACTION_A), "roof badge uses the faction color")
	_expect(tall["ring"].is_equal_approx(Palette.FACTION_A), "owner ring uses the faction color")
	_expect(int(tall["power"]) == BlockView.POWER_STEADY, "covered tile is steady power")
	_expect(is_equal_approx(tall["window"], BlockView.WINDOW_MIN + (1.0 - BlockView.WINDOW_MIN) * 0.5), "window state follows satisfaction (got %.2f)" % tall["window"])
	var low := BlockView.tile_style(session.view_tile(2, 1))
	_expect(is_equal_approx(low["height"], BlockView.TIER_HEIGHT[0]), "tier 0 nominal height")
	_expect(low["wall"].is_equal_approx(Palette.ZONE_C), "tier 0 C uses the C color")
	_expect(int(low["power"]) == BlockView.POWER_BROWNOUT, "brownout tile flagged")
	_expect(is_equal_approx(low["window"], BlockView.WINDOW_BROWNOUT), "brownout tile has the brownout window state")
	_expect(is_equal_approx(low["pollution_alpha"], 0.5 * BlockView.ALPHA_POLLUTION_MAX), "pollution alpha scales with pollution")
	var bare := BlockView.tile_style(session.view_tile(5, 5))
	_expect(bare["ring"].is_equal_approx(Palette.UNCLAIMED) and bare["fill"].is_equal_approx(Palette.UNCLAIMED), "neutral tile is unclaimed")
	_expect(is_equal_approx(bare["height"], 0.0), "neutral tile has no building")
	var mid := TileDelta.from_cell(0, 0)
	mid.owner = SliceConstants.Owner.FACTION_B
	mid.zone = SliceConstants.Zone.I
	mid.has_building = true
	mid.building_tier = 1
	var mid_style := BlockView.tile_style(mid)
	_expect(is_equal_approx(mid_style["height"], BlockView.TIER_HEIGHT[1]), "tier 1 nominal height")
	_expect(mid_style["wall"].is_equal_approx(Palette.ZONE_I) and mid_style["ring"].is_equal_approx(Palette.FACTION_B), "tier 1 I color, B ring")
	_expect(is_equal_approx(mid_style["window"], BlockView.WINDOW_UNPOWERED), "unpowered building has dark windows")
	_expect(BlockView.edge_color(0.9).is_equal_approx(Palette.ASPHALT.lerp(Palette.WARN, 0.9)), "congested edge mixes toward WARN")
	_expect(BlockView.edge_color(0.0).is_equal_approx(Palette.ASPHALT), "free edge is asphalt")

	# Only the touched block is rebuilt on an update: edit block 0,0 and watch 1,1 stay idle.
	var idle := view.block_view("1,1")
	var idle_before := idle.rebuild_count
	var near_before := near.rebuild_count
	var neutral := TileDelta.from_cell(3, 3)
	_emit(ServerEvent.with_tile_delta(neutral))
	_expect(idle.rebuild_count == idle_before, "untouched block 1,1 was not rebuilt")
	_expect(near.rebuild_count == near_before + 1, "block 0,0 rebuilt once for its tile")
	var summary := RegionSummary.new()
	summary.interest = InterestId.new(1, 1)
	summary.population = 8
	_emit(ServerEvent.with_region_summary(summary))
	_expect(idle.rebuild_count == idle_before + 1, "summary for 1,1 rebuilt that block")
	_expect(_summary_visible(idle) == 1, "summary block still shows one quad")

	# Optimistic claim shows up at once and the reject takes it back.
	session.send_command(GameCommand.claim_tile(4, 4))
	_expect(BlockView.tile_style(session.view_tile(4, 4))["ring"].is_equal_approx(Palette.FACTION_A), "pending claim draws the faction ring")
	_expect(near.rebuild_count == near_before + 2, "pending claim rebuilt block 0,0")
	_emit(ServerEvent.with_reject(CommandReject.new(GameCommand.claim_tile(4, 4), ReasonCode.Id.NOT_ADJACENT, "")))
	_expect(BlockView.tile_style(session.view_tile(4, 4))["ring"].is_equal_approx(Palette.UNCLAIMED), "reject restores the unclaimed ring")
	_expect(near.rebuild_count == near_before + 3, "reject rebuilt block 0,0 for the rollback")

	# Seam hand-off: the seam edge 7,3-8,3 and its junctions 8,3 / 8,4 belong to block 0,0 while
	# it is subscribed, whether or not 1,0 is; unsubscribing 0,0 hands them to 1,0.
	var open_right := InterestUpdate.new()
	open_right.add.append(InterestId.new(1, 0))
	_emit(ServerEvent.with_interest_update(open_right))
	_expect(near.segments_drawn.has(seam_key) and not neighbour.segments_drawn.has(seam_key), "seam segment drawn once, by block 0,0")
	_expect(near.corners_drawn.has(Vector2i(8, 3)) and near.corners_drawn.has(Vector2i(8, 4)), "seam junctions drawn by block 0,0")
	_expect(not neighbour.corners_drawn.has(Vector2i(8, 3)) and not neighbour.corners_drawn.has(Vector2i(8, 4)), "block 1,0 does not duplicate the seam junctions")
	var drop := InterestUpdate.new()
	drop.remove.append(InterestId.new(0, 0))
	_emit(ServerEvent.with_interest_update(drop))
	_expect(_summary_visible(near) == 1 and _mesh(near, "Roads") == null, "unsubscribed block collapses to the summary")
	_expect(near.brownout_count == 0, "brownout count cleared with the detail")
	_expect(neighbour.segments_drawn.has(seam_key), "1,0 draws the seam segment once 0,0 is gone")
	_expect(neighbour.corners_drawn.has(Vector2i(8, 3)) and neighbour.corners_drawn.has(Vector2i(8, 4)), "1,0 draws the seam junctions once 0,0 is gone")

	# Neighbour seam refresh: 0,0 and 0,1 subscribed; an edge inside 0,1 that reaches the corner
	# 8,8 (owned by 0,0 through tile 7,7) must make 0,0 draw that junction although only 0,1 and
	# 1,1 were dirty.
	var reopen := InterestUpdate.new()
	reopen.add.append(InterestId.new(0, 0))
	reopen.add.append(InterestId.new(0, 1))
	_emit(ServerEvent.with_interest_update(reopen))
	var south := view.block_view("0,1")
	var builds_before := near.geometry_builds
	var south_edge := WorldState.ordered_edge(Vector2i(7, 8), Vector2i(8, 8))
	_emit(ServerEvent.with_edge_delta(south_edge))
	_expect(near.geometry_builds == builds_before + 1, "block 0,0 refreshed its seam for an edge in 0,1 (builds %d -> %d)" % [builds_before, near.geometry_builds])
	_expect(near.corners_drawn.has(Vector2i(8, 8)), "block 0,0 draws the junction at 8,8")
	_expect(not south.corners_drawn.has(Vector2i(8, 8)) and south.corners_drawn.has(Vector2i(8, 9)), "block 0,1 draws only its own corner 8,9")
	var builds_idle := near.geometry_builds
	var far_edge := WorldState.ordered_edge(Vector2i(2, 12), Vector2i(3, 12))
	_emit(ServerEvent.with_edge_delta(far_edge))
	_expect(near.geometry_builds == builds_idle, "an edge away from the seam does not regenerate block 0,0")

	# All zones and tiers, rebuild budgets.
	_check_dense_block()
	_check_full_rebuild()

	# Camera: metres per tile, wheel steps, tile -> screen -> tile round trip and zoom clamp.
	camera.set_ortho_size(25.3 * CameraRig.TILE)
	camera.zoom_steps(1)
	_expect(is_equal_approx(camera.size, 22.0 * CameraRig.TILE), "one wheel notch divides the ortho size by 1.15 (got %.2f)" % camera.size)
	camera.zoom_steps(-1)
	_expect(is_equal_approx(camera.size, 25.3 * CameraRig.TILE), "one notch back restores it")
	camera.focus_tile(10, 10)
	camera.set_ortho_size(30.0 * CameraRig.TILE)
	var screen := camera.tile_to_screen(Vector2i(12, 9))
	_expect(camera.pick_tile(screen) == Vector2i(12, 9), "pick_tile inverts tile_to_screen (got %s)" % str(camera.pick_tile(screen)))
	_expect(camera.near < camera.far and camera.far > camera.position.y, "camera depth range covers the ground")
	camera.set_ortho_size(1.0)
	_expect(is_equal_approx(camera.size, CameraRig.SIZE_MIN), "ortho size clamps at SIZE_MIN")
	camera.set_ortho_size(999999.0)
	_expect(is_equal_approx(camera.size, CameraRig.SIZE_MAX), "ortho size clamps at SIZE_MAX")
	camera.focus_tile(-50, 500)
	_expect(camera.target.x >= 0.0 and camera.target.z <= SliceConstants.MAP_SIZE * CameraRig.TILE, "target clamped to the map")
	_expect(camera.current_block() == Vector2i(0, SliceConstants.BLOCKS_PER_AXIS - 1), "current_block follows the clamped target")
	var path := PlayInput.manhattan_path(Vector2i(2, 2), Vector2i(4, 3))
	_expect(path == ([Vector2i(3, 2), Vector2i(4, 2), Vector2i(4, 3)] as Array[Vector2i]), "manhattan path x first then y")
	_expect(Hud.format_duration(6 * 86400 + 23 * 3600 + 59 * 60 + 30) == "6d 23h 59m 30s", "duration formats d h m s")
	_expect(Hud.format_int(1234567) == "1,234,567" and Hud.format_int(-950) == "-950", "thousands separators")


## Block 2,2 fully built: 64 buildings cycling R / C / I by column and tier 0 / 1 / 2 by row on a
## road grid. Checks that every zone x tier appears, then that a one-tile change stays under
## BUDGET_BLOCK_MS (cold build time is reported, not asserted).
func _check_dense_block() -> void:
	var block := InterestId.new(2, 2)
	var open := InterestUpdate.new()
	open.add.append(block)
	_emit(ServerEvent.with_interest_update(open))
	var x0 := block.block_x * SliceConstants.INTEREST_BLOCK
	var y0 := block.block_y * SliceConstants.INTEREST_BLOCK
	var dense := view.block_view(block.key())
	# roads first so the building fronts face them
	for ty in SliceConstants.INTEREST_BLOCK:
		for tx in SliceConstants.INTEREST_BLOCK:
			var x := x0 + tx
			var y := y0 + ty
			if tx < SliceConstants.INTEREST_BLOCK - 1 and ty % 2 == 0:
				_emit(ServerEvent.with_edge_delta(WorldState.ordered_edge(Vector2i(x, y), Vector2i(x + 1, y))))
			if ty < SliceConstants.INTEREST_BLOCK - 1 and tx % 3 == 0:
				_emit(ServerEvent.with_edge_delta(WorldState.ordered_edge(Vector2i(x, y), Vector2i(x, y + 1))))
	for ty in SliceConstants.INTEREST_BLOCK:
		for tx in SliceConstants.INTEREST_BLOCK:
			var tile := TileDelta.from_cell(x0 + tx, y0 + ty)
			tile.owner = SliceConstants.Owner.FACTION_A if tx < 4 else SliceConstants.Owner.FACTION_B
			tile.zone = [SliceConstants.Zone.R, SliceConstants.Zone.C, SliceConstants.Zone.I][tx % 3]
			tile.has_building = true
			tile.building_tier = ty % 3
			tile.power_covered = true
			tile.satisfaction = 0.75
			tile.pollution = 0.25 if tile.zone == SliceConstants.Zone.I else 0.0
			_emit(ServerEvent.with_tile_delta(tile))
	# cold build: drop the per-tile cache and regenerate all 64 buildings in one pass
	dense.reset_geometry()
	view.rebuild_block(block.key())
	var cold_ms := view.last_update_ms
	_expect(int(dense.stats.get("generated", 0)) == 64, "cold rebuild generated all 64 buildings (got %s)" % str(dense.stats.get("generated")))
	var kinds: Dictionary = dense.stats.get("kinds", {})
	for zone in ["R", "C", "I"]:
		for tier in 3:
			var kind := "%s%d" % [zone, tier]
			_expect(kinds.has(kind), "dense block has a %s building (kinds %s)" % [kind, str(kinds)])
	_expect(int(dense.stats.get("buildings", 0)) == 64, "dense block has 64 buildings (got %s)" % str(dense.stats.get("buildings")))
	_expect(int(dense.stats.get("badges", 0)) == 64, "every building carries a roof badge")
	_expect(int(dense.stats.get("borders", 0)) > 0, "A / B frontier draws territory borders")
	_expect(int(dense.stats.get("trees", 0)) > 0 and int(dense.stats.get("lamps", 0)) > 0, "props placed (trees %s lamps %s)" % [str(dense.stats.get("trees")), str(dense.stats.get("lamps"))])
	var mesh: ArrayMesh = _mesh(dense, "Lots")
	var tris := 0
	if mesh != null:
		for s in mesh.get_surface_count():
			tris += mesh.surface_get_array_len(s) / 3
	print("VIEW_PERF dense block cold: 64 buildings generated + merged + roads + overlay + props in %.1f ms (block build %.1f ms), building mesh surfaces=%d tris=%d" % [
		cold_ms, dense.last_build_ms, mesh.get_surface_count() if mesh != null else 0, tris])

	# One tile changes tier: one building regenerated, the rest merged from the cache.
	var best := INF
	for i in 3:
		var tile := TileDelta.from_cell(x0 + 1 + i, y0 + 1)
		tile.owner = SliceConstants.Owner.FACTION_A
		tile.zone = SliceConstants.Zone.R
		tile.has_building = true
		tile.building_tier = 2
		tile.power_covered = true
		tile.satisfaction = 0.75
		_emit(ServerEvent.with_tile_delta(tile))
		best = minf(best, view.last_update_ms)
		print("VIEW_PERF   zone/tier change %d: update %.2f ms (block %.2f: sig %.2f, roads %.2f, pads %.2f, lots %.2f, overlay %.2f, street %.2f, instances %.2f)" % [
			i, view.last_update_ms, dense.last_build_ms, dense.stats.get("ms_sig", 0.0), dense.stats.get("ms_roads", 0.0), dense.stats.get("ms_pads", 0.0),
			dense.stats.get("ms_lots", 0.0), dense.stats.get("ms_overlay", 0.0), dense.stats.get("ms_street", 0.0), dense.stats.get("ms_instances", 0.0)])
		for k in ["ms_roads", "ms_pads", "ms_lots", "ms_overlay", "ms_street"]:
			dense.stats.erase(k)
		_expect(int(dense.stats.get("generated", 99)) == 1, "a one-tile change regenerates one building (got %s)" % str(dense.stats.get("generated")))
	print("VIEW_PERF one tile tier change: best of 3 = %.2f ms (budget %.0f ms)" % [best, BUDGET_BLOCK_MS])
	_expect(best <= BUDGET_BLOCK_MS, "one-tile change rebuild %.2f ms within %.0f ms" % [best, BUDGET_BLOCK_MS])

	# A new road edge inside the dense block: roads, pads, the two fronting buildings, street props.
	var road_best := INF
	for i in [1, 2, 4]:
		var a := Vector2i(x0 + i, y0 + 3)
		var bb := Vector2i(x0 + i, y0 + 4)
		_emit(ServerEvent.with_edge_delta(WorldState.ordered_edge(a, bb)))
		road_best = minf(road_best, view.last_update_ms)
		print("VIEW_PERF   road edge %d: update %.2f ms (block %.2f: sig %.2f, roads %.2f, pads %.2f, lots %.2f, overlay %.2f, street %.2f, instances %.2f) generated=%s" % [
			i, view.last_update_ms, dense.last_build_ms, dense.stats.get("ms_sig", 0.0), dense.stats.get("ms_roads", 0.0), dense.stats.get("ms_pads", 0.0),
			dense.stats.get("ms_lots", 0.0), dense.stats.get("ms_overlay", 0.0), dense.stats.get("ms_street", 0.0), dense.stats.get("ms_instances", 0.0),
			str(dense.stats.get("generated"))])
		for k in ["ms_roads", "ms_pads", "ms_lots", "ms_overlay", "ms_street"]:
			dense.stats.erase(k)
	print("VIEW_PERF one road edge: best of 3 = %.2f ms (budget %.0f ms)" % [road_best, BUDGET_BLOCK_MS])
	_expect(road_best <= BUDGET_BLOCK_MS, "road edge rebuild %.2f ms within %.0f ms" % [road_best, BUDGET_BLOCK_MS])

	# A power alert only touches the window state and the overlay.
	var alert := PowerAlert.new()
	alert.x = x0 + 2
	alert.y = y0 + 2
	alert.power_covered = true
	alert.brownout = true
	var builds_before := dense.geometry_builds
	_emit(ServerEvent.with_power_alert(alert))
	_expect(dense.geometry_builds == builds_before + 1 and int(dense.stats.get("generated", 99)) == 0, "a brownout regenerates no building")
	_expect(dense.brownout_count == 1, "brownout counted in the dense block")
	print("VIEW_PERF brownout alert: %.2f ms" % view.last_update_ms)
	_expect(view.last_update_ms <= BUDGET_BLOCK_MS, "brownout rebuild %.2f ms within budget" % view.last_update_ms)


## WELCOME dirties all 256 blocks with the dense block, 0,0 / 1,0 / 0,1 subscribed: the full
## pass must stay under BUDGET_ALL_MS (caches warm, signatures unchanged).
func _check_full_rebuild() -> void:
	var welcome := ServerWelcome.new()
	welcome.faction = SliceConstants.Owner.FACTION_A
	_emit(ServerEvent.with_welcome(welcome))
	_expect(view.last_dirty_count == SliceConstants.BLOCKS_PER_AXIS * SliceConstants.BLOCKS_PER_AXIS, "WELCOME rebuilt all %d blocks (got %d)" % [SliceConstants.BLOCKS_PER_AXIS * SliceConstants.BLOCKS_PER_AXIS, view.last_dirty_count])
	print("VIEW_PERF 256-block rebuild (WELCOME, %d detailed): %.1f ms (budget %.0f ms)" % [view.detailed_block_count(), view.last_update_ms, BUDGET_ALL_MS])
	_expect(view.last_update_ms <= BUDGET_ALL_MS, "256-block rebuild %.1f ms within %.0f ms" % [view.last_update_ms, BUDGET_ALL_MS])
	var dense := view.block_view("2,2")
	_expect(int(dense.stats.get("buildings", 0)) == 64, "dense block kept its buildings through the full rebuild")


func _summary_visible(block: BlockView) -> int:
	var node := block.get_node_or_null("Summary")
	if node == null:
		return -1
	return (node as MultiMeshInstance3D).multimesh.visible_instance_count


func _mesh(block: BlockView, layer: String) -> ArrayMesh:
	var node := block.get_node_or_null(layer)
	if node == null:
		return null
	return (node as MeshInstance3D).mesh as ArrayMesh


func _emit(event: ServerEvent) -> void:
	GameNet.event_received.emit(ServerEvent.from_dict(event.to_dict()))


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)

extends Node3D

## Headless check of the per-block live view: feeds a WorldView through a ClientSession and
## asserts that only dirty blocks are rebuilt, that the live layers carry the expected content
## (buildings per zone and tier, road segments and junctions, power / brownout / haze overlays),
## that a seam edge and a seam junction are drawn by exactly one block and hand over on
## subscription changes, that a neighbour refreshes its seam when an edge appears next to it,
## that rebuild costs stay inside the M4 budget (one block <= 8 ms, 256 blocks <= 2 s), and
## that the camera's tile <-> screen mapping round-trips in metres. Prints VIEW_OK and exits 0.
##   godot --headless --path . res://client/dev/view_check.tscn
##
## Windowed stress probe (worst case for the frame budget, not part of the headless check):
##   godot --path . --resolution 1920x1080 res://client/dev/view_check.tscn -- --stress \
##     [--stress-size <metres>] [--screenshot <png>]
## Nine subscribed blocks (1..3 x 1..3) full of buildings on a road grid (576 buildings), lit
## like main.tscn (LiveLighting + Sun), camera on the middle at --stress-size (default 660 m);
## WorldView prints VIEW_PERF every 60 frames; quits after STRESS_FRAMES with the screenshot.

const BUDGET_BLOCK_MS := 8.0
const BUDGET_ALL_MS := 2000.0
const STRESS_FRAMES := 300
const STRESS_SIZE_DEFAULT := 660.0

var _failures: Array[String] = []
var session: ClientSession
var view: WorldView
var camera: CameraRig
var _stress := false
var _stress_frames := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_stress = args.has("--stress") and DisplayServer.get_name() != "headless"
	if _stress:
		OS.set_environment("GAMECITY_VIEW_PERF", "1")
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
	if _stress:
		_stress_setup(args)
		return
	_run()
	if _failures.is_empty():
		print("VIEW_OK")
		get_tree().quit(0)
	else:
		for line in _failures:
			printerr("VIEW_FAIL " + line)
		get_tree().quit(1)


func _stress_setup(args: PackedStringArray) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	add_child(sun)
	var env := LiveLighting.new()
	env.name = "Env"
	env.sun_path = ^"../Sun"
	env.camera_path = ^"../Camera"
	add_child(env)
	var welcome := ServerWelcome.new()
	welcome.faction = SliceConstants.Owner.FACTION_A
	_emit(ServerEvent.with_welcome(welcome))
	_emit(ServerEvent.with_match_start(MatchStart.new()))
	var open := InterestUpdate.new()
	for by in range(1, 4):
		for bx in range(1, 4):
			open.add.append(InterestId.new(bx, by))
	_emit(ServerEvent.with_interest_update(open))
	# the whole district arrives as one burst of events, like a server interest add: the view
	# coalesces them into one rebuild pass per block (flush_dirty at the end)
	var t0 := Time.get_ticks_usec()
	var n := 0
	for y in range(8, 32):
		for x in range(8, 32):
			if x < 31 and y % 2 == 0:
				_emit_raw(ServerEvent.with_edge_delta(WorldState.ordered_edge(Vector2i(x, y), Vector2i(x + 1, y))))
			if y < 31 and x % 3 == 0:
				_emit_raw(ServerEvent.with_edge_delta(WorldState.ordered_edge(Vector2i(x, y), Vector2i(x, y + 1))))
	for y in range(8, 32):
		for x in range(8, 32):
			var tile := TileDelta.from_cell(x, y)
			tile.owner = SliceConstants.Owner.FACTION_A if x < 20 else SliceConstants.Owner.FACTION_B
			tile.zone = [SliceConstants.Zone.R, SliceConstants.Zone.C, SliceConstants.Zone.I][(x + y) % 3]
			tile.has_building = true
			tile.building_tier = (x / 2 + y) % 3
			tile.power_covered = true
			tile.brownout = (x + y) % 11 == 0
			tile.satisfaction = 0.75
			tile.pollution = 0.3 if tile.zone == SliceConstants.Zone.I else 0.0
			_emit_raw(ServerEvent.with_tile_delta(tile))
			n += 1
	var t_feed := (Time.get_ticks_usec() - t0) / 1000.0
	view.flush_dirty()
	print("VIEW_STRESS %d tiles fed in %.0f ms, one coalesced rebuild pass of %d detailed blocks (%d buildings) in %.0f ms" % [
		n, t_feed, view.detailed_block_count(), _stress_buildings(), view.last_update_ms])
	camera.focus_tile(20, 20)
	var size := STRESS_SIZE_DEFAULT
	var idx := args.find("--stress-size")
	if idx != -1 and idx + 1 < args.size() and String(args[idx + 1]).is_valid_float():
		size = float(args[idx + 1])
	camera.set_ortho_size(size)


func _process(_delta: float) -> void:
	if not _stress:
		return
	_stress_frames += 1
	if _stress_frames == STRESS_FRAMES:
		var args := OS.get_cmdline_user_args()
		var idx := args.find("--screenshot")
		if idx != -1 and idx + 1 < args.size():
			await RenderingServer.frame_post_draw
			var image := get_viewport().get_texture().get_image()
			var err := image.save_png(args[idx + 1])
			print("SCREENSHOT %s %s %dx%d" % [args[idx + 1], error_string(err), image.get_width(), image.get_height()])
		get_tree().quit(0)


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
	_expect(_mesh(near, "Roads") != null and _mesh(near, "Lots0") != null and _mesh(near, "Overlay") != null, "subscribed block has ground, building and overlay meshes")
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
	view.flush_dirty()
	_expect(BlockView.tile_style(session.view_tile(4, 4))["ring"].is_equal_approx(Palette.FACTION_A), "pending claim draws the faction ring")
	_expect(near.rebuild_count == near_before + 2, "pending claim rebuilt block 0,0")
	_emit(ServerEvent.with_reject(CommandReject.new(GameCommand.claim_tile(4, 4), ReasonCode.Id.NOT_ADJACENT, "")))
	_expect(BlockView.tile_style(session.view_tile(4, 4))["ring"].is_equal_approx(Palette.UNCLAIMED), "reject restores the unclaimed ring")
	_expect(near.rebuild_count == near_before + 3, "reject rebuilt block 0,0 for the rollback")

	# Seam hand-off. The seam edge 7,3-8,3 is the street piece between the nodes of tiles 7,3 and
	# 8,3 (corners 8,4 and 9,4 on line y=4). While 0,0 is subscribed it draws the segment and the
	# corner of its own tile 7,3; corner 9,4 belongs to 1,0 once that block is subscribed (its
	# node tile 8,3) and falls back to the segment owner while it is not. Unsubscribing 0,0 hands
	# segment and both corners to 1,0.
	_expect(near.corners_drawn.has(Vector2i(8, 4)) and near.corners_drawn.has(Vector2i(9, 4)), "0,0 draws both seam corners while 1,0 is unsubscribed")
	var open_right := InterestUpdate.new()
	open_right.add.append(InterestId.new(1, 0))
	_emit(ServerEvent.with_interest_update(open_right))
	_expect(near.segments_drawn.has(seam_key) and not neighbour.segments_drawn.has(seam_key), "seam segment drawn once, by block 0,0")
	_expect(near.corners_drawn.has(Vector2i(8, 4)) and not near.corners_drawn.has(Vector2i(9, 4)), "0,0 keeps its node corner 8,4 and gives 9,4 to 1,0")
	_expect(neighbour.corners_drawn.has(Vector2i(9, 4)) and not neighbour.corners_drawn.has(Vector2i(8, 4)), "1,0 draws corner 9,4 only")
	var drop := InterestUpdate.new()
	drop.remove.append(InterestId.new(0, 0))
	_emit(ServerEvent.with_interest_update(drop))
	_expect(_summary_visible(near) == 1 and _mesh(near, "Roads") == null, "unsubscribed block collapses to the summary")
	_expect(near.brownout_count == 0, "brownout count cleared with the detail")
	_expect(neighbour.segments_drawn.has(seam_key), "1,0 draws the seam segment once 0,0 is gone")
	_expect(neighbour.corners_drawn.has(Vector2i(8, 4)) and neighbour.corners_drawn.has(Vector2i(9, 4)), "1,0 draws both seam corners once 0,0 is gone")

	# Neighbour seam refresh: 0,0 and 0,1 subscribed, a building on tile 4,8 (block 0,1). The edge
	# 3,7-4,7 inside 0,0 is the street on line y=8 along the north side of tile 4,8: that tile's
	# front and pad change, so 0,1 must regenerate although only 0,0 was dirty; the junctions at
	# 4,8 and 5,8 are 0,0's (nodes of its tiles 3,7 and 4,7).
	var reopen := InterestUpdate.new()
	reopen.add.append(InterestId.new(0, 0))
	reopen.add.append(InterestId.new(0, 1))
	_emit(ServerEvent.with_interest_update(reopen))
	var south := view.block_view("0,1")
	var fronting := TileDelta.from_cell(4, 8)
	fronting.owner = SliceConstants.Owner.FACTION_A
	fronting.zone = SliceConstants.Zone.R
	fronting.has_building = true
	_emit(ServerEvent.with_tile_delta(fronting))
	var builds_before := south.geometry_builds
	var seam_street := WorldState.ordered_edge(Vector2i(3, 7), Vector2i(4, 7))
	_emit(ServerEvent.with_edge_delta(seam_street))
	_expect(south.geometry_builds == builds_before + 1, "block 0,1 refreshed for a street along its north edge (builds %d -> %d)" % [builds_before, south.geometry_builds])
	_expect(int(south.stats.get("generated", 0)) == 1, "tile 4,8 regenerated its building to face the new street (generated %s)" % str(south.stats.get("generated")))
	_expect(near.corners_drawn.has(Vector2i(4, 8)) and near.corners_drawn.has(Vector2i(5, 8)), "block 0,0 draws the junctions of its own nodes 4,8 and 5,8")
	_expect(not south.corners_drawn.has(Vector2i(4, 8)) and not south.corners_drawn.has(Vector2i(5, 8)), "block 0,1 does not duplicate them")
	var builds_idle := south.geometry_builds
	var far_edge := WorldState.ordered_edge(Vector2i(1, 1), Vector2i(1, 2))
	_emit(ServerEvent.with_edge_delta(far_edge))
	_expect(south.geometry_builds == builds_idle, "an edge away from the seam does not regenerate block 0,1")

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
	var tris := 0
	var surfaces := 0
	for layer in ["Lots0", "Lots1"]:
		var mesh: ArrayMesh = _mesh(dense, layer)
		if mesh == null:
			continue
		surfaces += mesh.get_surface_count()
		for s in mesh.get_surface_count():
			tris += mesh.surface_get_array_len(s) / 3
	print("VIEW_PERF dense block cold: 64 buildings generated + merged + roads + overlay + props in %.1f ms (block build %.1f ms), lot mesh surfaces=%d tris=%d" % [
		cold_ms, dense.last_build_ms, surfaces, tris])

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


## Wire round trip, then the per-frame rebuild pass the view would otherwise run deferred, so
## every assertion below sees the rebuilt state synchronously.
func _emit(event: ServerEvent) -> void:
	_emit_raw(event)
	view.flush_dirty()


func _emit_raw(event: ServerEvent) -> void:
	GameNet.event_received.emit(ServerEvent.from_dict(event.to_dict()))


func _stress_buildings() -> int:
	var n := 0
	for by in range(1, 4):
		for bx in range(1, 4):
			n += int(view.block_view("%d,%d" % [bx, by]).stats.get("buildings", 0))
	return n


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)

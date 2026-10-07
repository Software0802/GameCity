extends Node3D

## Headless check of the per-block view: feeds a WorldView through a ClientSession
## and asserts that only dirty blocks are rebuilt, that layers carry the expected
## instance counts, that brownout tiles are counted for the flicker, that
## unsubscribed blocks collapse to their summary quad, and that the camera's
## tile <-> screen mapping round-trips. Prints VIEW_OK and exits 0.
##   godot --headless --path . res://client/dev/view_check.tscn

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
	_expect(_visible(far, "Summary") == 1, "unsubscribed block shows its summary quad")
	_expect(far.get_node_or_null("Rings") == null, "unsubscribed block has no detail layers")

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

	var near := view.block_view("0,0")
	_expect(_visible(near, "Summary") == 0, "subscribed block hides its summary quad")
	_expect(_visible(near, "Rings") == BlockView.TILE_COUNT, "64 rings in a subscribed block")
	_expect(_visible(near, "Fills") == BlockView.TILE_COUNT, "64 fills in a subscribed block")
	_expect(_visible(near, "Buildings") == 2, "two buildings (got %d)" % _visible(near, "Buildings"))
	_expect(_visible(near, "Roofs") == 2, "two roof badges")
	_expect(_visible(near, "Power") == 1, "one steady power quad")
	_expect(_visible(near, "Brownout") == 1, "one brownout quad")
	_expect(near.brownout_count == 1, "brownout_count feeds the flicker")
	_expect(_visible(near, "Pollution") == 1, "one pollution quad")
	_expect(_visible(near, "Edges") == 2, "inner edge and seam edge drawn by block 0,0 (got %d)" % _visible(near, "Edges"))
	var neighbour := view.block_view("1,0")
	_expect(neighbour.get_node_or_null("Edges") == null, "unsubscribed neighbour draws nothing")

	# Visual mapping (MultiMesh instance data cannot be read back headless, so the
	# pure style function is checked instead): tier height, dense color, badge, edge mix.
	var tall := BlockView.tile_style(session.view_tile(1, 1))
	_expect(is_equal_approx(tall["height"], 3.5), "tier 2 building is 3.5 high (got %.2f)" % tall["height"])
	_expect(tall["wall"].is_equal_approx(Palette.ZONE_R_DENSE), "tier 2 R box uses the dense R color")
	_expect(tall["fill"].is_equal_approx(Palette.ZONE_R_DENSE), "tier 2 R lot fill uses the dense R color")
	_expect(tall["roof"].is_equal_approx(Palette.FACTION_A), "roof badge uses the faction color")
	_expect(tall["ring"].is_equal_approx(Palette.FACTION_A), "owner ring uses the faction color")
	_expect(int(tall["power"]) == BlockView.POWER_STEADY, "covered tile is steady power")
	var low := BlockView.tile_style(session.view_tile(2, 1))
	_expect(is_equal_approx(low["height"], 1.0), "tier 0 building is 1.0 high")
	_expect(low["wall"].is_equal_approx(Palette.ZONE_C), "tier 0 C box uses the C color")
	_expect(int(low["power"]) == BlockView.POWER_BROWNOUT, "brownout tile flagged")
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
	_expect(is_equal_approx(mid_style["height"], 2.0), "tier 1 building is 2.0 high")
	_expect(mid_style["wall"].is_equal_approx(Palette.ZONE_I) and mid_style["ring"].is_equal_approx(Palette.FACTION_B), "tier 1 I box, B ring")
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

	# Optimistic claim shows up at once and the reject takes it back.
	session.send_command(GameCommand.claim_tile(4, 4))
	_expect(BlockView.tile_style(session.view_tile(4, 4))["ring"].is_equal_approx(Palette.FACTION_A), "pending claim draws the faction ring")
	_expect(near.rebuild_count == near_before + 2, "pending claim rebuilt block 0,0")
	_emit(ServerEvent.with_reject(CommandReject.new(GameCommand.claim_tile(4, 4), ReasonCode.Id.NOT_ADJACENT, "")))
	_expect(BlockView.tile_style(session.view_tile(4, 4))["ring"].is_equal_approx(Palette.UNCLAIMED), "reject restores the unclaimed ring")
	_expect(near.rebuild_count == near_before + 3, "reject rebuilt block 0,0 for the rollback")

	# Seam hand-off: the seam edge 7,3-8,3 is drawn by block 0,0 while 1,0 is unsubscribed;
	# once 1,0 is subscribed it still belongs to 0,0 (a's block). Unsubscribing 0,0 hands
	# it to 1,0, which must be rebuilt by the neighbour-dirty rule.
	var open_right := InterestUpdate.new()
	open_right.add.append(InterestId.new(1, 0))
	_emit(ServerEvent.with_interest_update(open_right))
	_expect(_visible(near, "Edges") == 2, "0,0 keeps the seam edge while subscribed")
	_expect(_visible(neighbour, "Edges") == 0, "1,0 does not duplicate the seam edge")

	# Unsubscribing collapses the block back to its summary and hands the seam edge over.
	var drop := InterestUpdate.new()
	drop.remove.append(InterestId.new(0, 0))
	_emit(ServerEvent.with_interest_update(drop))
	_expect(_visible(near, "Summary") == 1 and _visible(near, "Rings") == 0, "unsubscribed block collapses to the summary")
	_expect(near.brownout_count == 0, "brownout count cleared with the detail")
	_expect(_visible(neighbour, "Edges") == 1, "1,0 draws the seam edge once 0,0 is gone (got %d)" % _visible(neighbour, "Edges"))
	camera.set_ortho_size(25.3)
	camera.zoom_steps(1)
	_expect(is_equal_approx(camera.size, 22.0), "one wheel notch divides the ortho size by 1.15 (got %.2f)" % camera.size)
	camera.zoom_steps(-1)
	_expect(is_equal_approx(camera.size, 25.3), "one notch back restores it")

	# Camera: tile -> screen -> tile round trip and zoom clamp.
	camera.focus_tile(10, 10)
	camera.set_ortho_size(30.0)
	var screen := camera.tile_to_screen(Vector2i(12, 9))
	_expect(camera.pick_tile(screen) == Vector2i(12, 9), "pick_tile inverts tile_to_screen (got %s)" % str(camera.pick_tile(screen)))
	camera.set_ortho_size(1.0)
	_expect(is_equal_approx(camera.size, CameraRig.SIZE_MIN), "ortho size clamps at SIZE_MIN")
	camera.set_ortho_size(9999.0)
	_expect(is_equal_approx(camera.size, CameraRig.SIZE_MAX), "ortho size clamps at SIZE_MAX")
	camera.focus_tile(-50, 500)
	_expect(camera.target.x >= 0.0 and camera.target.z <= SliceConstants.MAP_SIZE, "target clamped to the map")
	_expect(camera.current_block() == Vector2i(0, SliceConstants.BLOCKS_PER_AXIS - 1), "current_block follows the clamped target")
	var path := PlayInput.manhattan_path(Vector2i(2, 2), Vector2i(4, 3))
	_expect(path == ([Vector2i(3, 2), Vector2i(4, 2), Vector2i(4, 3)] as Array[Vector2i]), "manhattan path x first then y")
	_expect(Hud.format_duration(6 * 86400 + 23 * 3600 + 59 * 60 + 30) == "6d 23h 59m 30s", "duration formats d h m s")
	_expect(Hud.format_int(1234567) == "1,234,567" and Hud.format_int(-950) == "-950", "thousands separators")


func _visible(block: BlockView, layer: String) -> int:
	var node := block.get_node_or_null(layer)
	if node == null:
		return -1
	return (node as MultiMeshInstance3D).multimesh.visible_instance_count


func _emit(event: ServerEvent) -> void:
	GameNet.event_received.emit(ServerEvent.from_dict(event.to_dict()))


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)

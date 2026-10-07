class_name StubServer
extends Node

## Offline stand-in for the handshake server, active only with --stub. It injects
## events through GameNet.event_received exactly as server_events_rpc would, so the
## session, HUD, and view run their production paths without a server process.
##
## The stub runs a real WorldState (server/world_state.gd) loaded from a scripted
## save, so clicks get the real accept / reject rules; the economy numbers it
## reports in FactionState are placeholders. For the screenshot it also keeps one
## edge congested, one tile in brownout, and the grid-storm crisis active.
##
## Scripted world: faction A owns its spawn [0,8)² with R / C / I lots, roads, and a
## plant at (4,4); faction B owns its real spawn and a patch at x 12–15 inside block
## (1,0), the border block of A's spawn, so both faction colors fit in one frame.

const TOKEN_PREFIX := "stub-"
## 6d 23h 59m 30s, so the HUD clock shows every unit.
const ROUND_LEFT_SEC := 6 * 86400 + 23 * 3600 + 59 * 60 + 30
const HOT_EDGE_A := Vector2i(4, 4)
const HOT_EDGE_B := Vector2i(5, 4)
const HOT_CONGESTION := 0.9
const BROWNOUT_TILE := Vector2i(3, 3)
const B_PATCH_X0 := 12
const B_PATCH_X1 := 15
const PLANT_A := Vector2i(4, 4)
const PLANT_B := Vector2i(14, 4)

var session: ClientSession = null
var world: WorldState = null
var faction: int = SliceConstants.Owner.FACTION_A
var tick: int = 0
var round_ends_at: int = 0
var treasury: float = float(SliceConstants.START_TREASURY)
var tax_rate: float = SliceConstants.TAX_RATE_DEFAULT
var camera_block: InterestId = WorldState.spawn_block(SliceConstants.Owner.FACTION_A)

var _subscribed: Dictionary = {}
var _timer: Timer


func start(p_session: ClientSession, display_name: String) -> void:
	session = p_session
	session.command_sent.connect(_on_command)
	world = WorldState.from_save_dict(scripted_save())
	# Settle power coverage before the first snapshot; only the score of this tick is sent.
	var settle: Array = world.sim_tick(0)
	var now := int(Time.get_unix_time_from_system())
	round_ends_at = now + ROUND_LEFT_SEC

	var welcome := ServerWelcome.new()
	welcome.token = TOKEN_PREFIX + "%08x" % (randi() & 0xFFFFFFFF)
	welcome.player_id = 1
	welcome.faction = faction
	welcome.name = display_name
	welcome.returning = false
	_emit(ServerEvent.with_welcome(welcome))

	var start := MatchStart.new()
	start.round_seconds = SliceConstants.ROUND_SECONDS_DEFAULT
	start.round_ends_at_unix = round_ends_at
	start.server_unix = now
	start.pace = SliceConstants.PACE_DEFAULT
	_emit(ServerEvent.with_match_start(start))

	_refresh_interest()

	var crisis := CrisisEvent.new()
	crisis.crisis_id = "stub_storm"
	crisis.kind = CrisisEvent.KIND_GRID_STORM
	crisis.active = true
	crisis.detail = "stub"
	crisis.ends_at_unix = now + SliceConstants.CRISIS_DURATION_SEC
	world.crisis_active = true
	_emit(ServerEvent.with_crisis_event(crisis))

	var brownout := PowerAlert.new()
	brownout.x = BROWNOUT_TILE.x
	brownout.y = BROWNOUT_TILE.y
	brownout.power_covered = true
	brownout.brownout = true
	_emit(ServerEvent.with_power_alert(brownout))

	_emit_hot_congestion()
	_emit_faction_state()
	_emit_score(settle)

	_timer = Timer.new()
	_timer.name = "StubTick"
	_timer.wait_time = SliceConstants.SIM_TICK_SEC
	_timer.timeout.connect(_on_tick)
	add_child(_timer)
	_timer.start()


func set_camera_block(block_x: int, block_y: int) -> void:
	camera_block = InterestId.new(block_x, block_y)
	_refresh_interest()


func _on_command(cmd: GameCommand) -> void:
	if cmd.kind == GameCommand.Kind.SET_TAX_RATE:
		var shape := cmd.validate_shape()
		if shape != ReasonCode.Id.OK:
			_reject(cmd, shape, "stub")
			return
		tax_rate = cmd.rate
		_emit_faction_state()
		return
	var cost := _cost(cmd)
	if cost > treasury:
		_reject(cmd, ReasonCode.Id.INSUFFICIENT_FUNDS, "stub")
		return
	var result: Dictionary = world.apply(faction, cmd)
	var reason := int(result["reason"])
	if reason != ReasonCode.Id.OK:
		_reject(cmd, reason, str(result["detail"]))
		return
	treasury -= cost
	_refresh_interest()
	_publish(result["events"])
	_emit_faction_state()


func _on_tick() -> void:
	tick += 1
	treasury += _income_per_sec()
	var events: Array = world.sim_tick(tick)
	var without_score: Array = []
	for event in events:
		if event.kind == ServerEvent.Kind.SCORE_TICK:
			continue
		without_score.append(event)
	_publish(without_score)
	_emit_hot_congestion()
	_emit_faction_state()
	_emit_score(events)


## Sends the ScoreTick found in a sim_tick result with the wall-clock seconds_remaining
## the dedicated server will fill in (wave 0's WorldState writes 0 there).
func _emit_score(events: Array) -> void:
	for event in events:
		if event.kind != ServerEvent.Kind.SCORE_TICK or event.score_tick == null:
			continue
		event.score_tick.seconds_remaining = maxi(0, round_ends_at - int(Time.get_unix_time_from_system()))
		_emit(event)
		return


func _emit_hot_congestion() -> void:
	if world.find_edge(HOT_EDGE_A, HOT_EDGE_B) == null:
		return
	var alert := CongestionAlert.new()
	alert.a = HOT_EDGE_A
	alert.b = HOT_EDGE_B
	alert.congestion = HOT_CONGESTION
	_emit(ServerEvent.with_congestion_alert(alert))


func _emit_faction_state() -> void:
	var state := FactionState.new()
	state.faction = faction
	state.treasury = treasury
	state.income_per_sec = _income_per_sec()
	state.population = _population()
	state.jobs = _jobs()
	state.technicians = 0
	state.tax_rate = tax_rate
	var gap := float(state.jobs - state.population)
	state.demand_r = clampf(gap / 20.0, -1.0, 1.0)
	state.demand_c = clampf(-gap / 20.0, -1.0, 1.0)
	state.demand_i = clampf(-gap / 40.0, -1.0, 1.0)
	var plants := _plant_count()
	var capacity := plants * SliceConstants.POWER_PLANT_CAPACITY
	if world.crisis_active:
		capacity = int(capacity * SliceConstants.CRISIS_CAPACITY_FACTOR)
	state.power_capacity = capacity
	state.power_load = _power_load()
	_emit(ServerEvent.with_faction_state(state))


func _income_per_sec() -> float:
	var scale := tax_rate / SliceConstants.TAX_RATE_DEFAULT
	var income := (
		_population() * SliceConstants.INCOME_PER_POP_PER_SEC
		+ _jobs() * SliceConstants.INCOME_PER_JOB_PER_SEC
	) * scale
	return income - _plant_count() * SliceConstants.UPKEEP_POWER_PER_SEC


func _population() -> int:
	var total := 0
	for y in SliceConstants.MAP_SIZE:
		for x in SliceConstants.MAP_SIZE:
			var tile := world.tile_at(x, y)
			if tile.owner == faction and tile.zone == SliceConstants.Zone.R and tile.has_building:
				total += SliceConstants.TIER_POP[clampi(tile.building_tier, 0, 2)]
	return total


func _jobs() -> int:
	var total := 0
	for y in SliceConstants.MAP_SIZE:
		for x in SliceConstants.MAP_SIZE:
			var tile := world.tile_at(x, y)
			if tile.owner != faction or not tile.has_building:
				continue
			if tile.zone == SliceConstants.Zone.C or tile.zone == SliceConstants.Zone.I:
				total += SliceConstants.TIER_JOBS[clampi(tile.building_tier, 0, 2)]
	return total


func _plant_count() -> int:
	var count := 0
	for y in SliceConstants.MAP_SIZE:
		for x in SliceConstants.MAP_SIZE:
			if world.has_power_source(x, y) and world.tile_at(x, y).owner == faction:
				count += 1
	return count


func _power_load() -> int:
	var load := 0
	for y in SliceConstants.MAP_SIZE:
		for x in SliceConstants.MAP_SIZE:
			var tile := world.tile_at(x, y)
			if tile.owner == faction and tile.has_building and tile.power_covered:
				load += tile.building_tier + 1
	return load


func _cost(cmd: GameCommand) -> float:
	match cmd.kind:
		GameCommand.Kind.CLAIM_TILE:
			return float(SliceConstants.COST_CLAIM_BASE)
		GameCommand.Kind.ADD_EDGE:
			return float(SliceConstants.COST_EDGE)
		GameCommand.Kind.PLACE_POWER:
			return float(SliceConstants.COST_POWER)
		_:
			return 0.0


func _reject(cmd: GameCommand, reason: int, detail: String) -> void:
	_emit(ServerEvent.with_reject(CommandReject.new(cmd, reason, detail)))


## Same routing as net_authority: a local event the client is not subscribed to
## collapses into a RegionSummary for its block.
func _publish(events: Array) -> void:
	var summaries: Dictionary = {}
	for event in events:
		var blocks := _event_blocks(event)
		if blocks.is_empty() or _sees_any(blocks):
			_emit(event)
			continue
		for block in blocks:
			summaries[block.key()] = block
	for key in summaries:
		_emit(ServerEvent.with_region_summary(world.summary_for(summaries[key])))


func _refresh_interest() -> void:
	var wanted: Dictionary = {}
	for block in world.interest_for(faction, camera_block):
		wanted[block.key()] = block
	var update := InterestUpdate.new()
	for key in wanted:
		if not _subscribed.has(key):
			update.add.append(wanted[key])
	for key in _subscribed:
		if not wanted.has(key):
			update.remove.append(InterestId.from_key(str(key)))
	_subscribed.clear()
	for key in wanted:
		_subscribed[key] = true
	if update.add.is_empty() and update.remove.is_empty():
		return
	_emit(ServerEvent.with_interest_update(update))
	for block in update.add:
		for tile in world.tiles_in_block(block):
			_emit(ServerEvent.with_tile_delta(tile))
		for edge in world.edges_in_block(block):
			_emit(ServerEvent.with_edge_delta(edge))
	# Neighbouring blocks the client does not see get a summary so they are not blank.
	for block in update.add:
		for step in WorldState.ORTHOGONAL:
			var nb := InterestId.new(block.block_x + step.x, block.block_y + step.y)
			if nb.block_x < 0 or nb.block_y < 0:
				continue
			if nb.block_x >= SliceConstants.BLOCKS_PER_AXIS or nb.block_y >= SliceConstants.BLOCKS_PER_AXIS:
				continue
			if not _subscribed.has(nb.key()):
				_emit(ServerEvent.with_region_summary(world.summary_for(nb)))


func _sees_any(blocks: Array) -> bool:
	for block in blocks:
		if _subscribed.has(block.key()):
			return true
	return false


func _event_blocks(event: ServerEvent) -> Array:
	var blocks: Array = []
	match event.kind:
		ServerEvent.Kind.TILE_DELTA:
			if event.tile_delta != null:
				blocks.append(InterestId.from_tile(event.tile_delta.x, event.tile_delta.y))
		ServerEvent.Kind.POWER_ALERT:
			if event.power_alert != null:
				blocks.append(InterestId.from_tile(event.power_alert.x, event.power_alert.y))
		ServerEvent.Kind.EDGE_DELTA:
			if event.edge_delta != null:
				blocks.append(InterestId.from_tile(event.edge_delta.a.x, event.edge_delta.a.y))
				blocks.append(InterestId.from_tile(event.edge_delta.b.x, event.edge_delta.b.y))
		ServerEvent.Kind.CONGESTION_ALERT:
			if event.congestion_alert != null:
				blocks.append(InterestId.from_tile(event.congestion_alert.a.x, event.congestion_alert.a.y))
				blocks.append(InterestId.from_tile(event.congestion_alert.b.x, event.congestion_alert.b.y))
	return blocks


## Wire round trip, as server_events_rpc does on a real connection.
func _emit(event: ServerEvent) -> void:
	GameNet.event_received.emit(ServerEvent.from_dict(event.to_dict()))


## Save envelope "world" slot (docs/plans/m2-city-phase.md) describing the demo city.
static func scripted_save() -> Dictionary:
	var tiles: Array = []
	var edges: Array = []
	var sources: Array = []
	var spawn := WorldState.SPAWN_SIZE

	# Faction A spawn with lots.
	var a_lots := {
		Vector2i(1, 1): [SliceConstants.Zone.R, 0, 0.0],
		Vector2i(2, 1): [SliceConstants.Zone.R, 1, 0.0],
		Vector2i(3, 1): [SliceConstants.Zone.R, 2, 0.0],
		Vector2i(1, 2): [SliceConstants.Zone.R, 1, 0.0],
		Vector2i(2, 2): [SliceConstants.Zone.R, 2, 0.0],
		Vector2i(3, 2): [SliceConstants.Zone.R, 0, 0.0],
		Vector2i(1, 3): [SliceConstants.Zone.R, 0, 0.0],
		Vector2i(2, 3): [SliceConstants.Zone.R, 1, 0.0],
		Vector2i(3, 3): [SliceConstants.Zone.R, 1, 0.0],
		Vector2i(5, 1): [SliceConstants.Zone.C, 1, 0.0],
		Vector2i(6, 1): [SliceConstants.Zone.C, 2, 0.0],
		Vector2i(5, 2): [SliceConstants.Zone.C, 0, 0.0],
		Vector2i(6, 2): [SliceConstants.Zone.C, 1, 0.0],
		Vector2i(1, 6): [SliceConstants.Zone.I, 0, 0.5],
		Vector2i(2, 6): [SliceConstants.Zone.I, 1, 0.75],
		Vector2i(6, 6): [SliceConstants.Zone.I, 0, 0.25],
	}
	for y in spawn:
		for x in spawn:
			var cell := Vector2i(x, y)
			if a_lots.has(cell):
				var lot: Array = a_lots[cell]
				tiles.append(_tile(cell, SliceConstants.Owner.FACTION_A, lot[0], lot[1], lot[2]))
			else:
				tiles.append(_tile(cell, SliceConstants.Owner.FACTION_A, SliceConstants.Zone.NONE, 0, 0.0))
	for x in spawn - 1:
		edges.append(_edge(Vector2i(x, 4), Vector2i(x + 1, 4)))
		edges.append(_edge(Vector2i(x, 0), Vector2i(x + 1, 0)))
	for y in spawn - 1:
		edges.append(_edge(Vector2i(4, y), Vector2i(4, y + 1)))
		edges.append(_edge(Vector2i(7, y), Vector2i(7, y + 1)))
	sources.append(SliceConstants.tile_id(PLANT_A.x, PLANT_A.y))

	# Faction B real spawn, bare.
	for y in spawn:
		for x in spawn:
			tiles.append(_tile(
				WorldState.SPAWN_B + Vector2i(x, y), SliceConstants.Owner.FACTION_B, SliceConstants.Zone.NONE, 0, 0.0
			))

	# Faction B patch in block (1,0).
	var b_lots := {
		Vector2i(12, 1): [SliceConstants.Zone.R, 1, 0.0],
		Vector2i(13, 1): [SliceConstants.Zone.R, 2, 0.0],
		Vector2i(14, 2): [SliceConstants.Zone.C, 2, 0.0],
		Vector2i(15, 2): [SliceConstants.Zone.C, 1, 0.0],
		Vector2i(13, 5): [SliceConstants.Zone.I, 0, 0.75],
		Vector2i(13, 6): [SliceConstants.Zone.I, 1, 0.5],
	}
	for y in spawn:
		for x in range(B_PATCH_X0, B_PATCH_X1 + 1):
			var cell := Vector2i(x, y)
			if b_lots.has(cell):
				var lot: Array = b_lots[cell]
				tiles.append(_tile(cell, SliceConstants.Owner.FACTION_B, lot[0], lot[1], lot[2]))
			else:
				tiles.append(_tile(cell, SliceConstants.Owner.FACTION_B, SliceConstants.Zone.NONE, 0, 0.0))
	for x in range(B_PATCH_X0, B_PATCH_X1):
		edges.append(_edge(Vector2i(x, 3), Vector2i(x + 1, 3)))
	for y in spawn - 1:
		edges.append(_edge(Vector2i(14, y), Vector2i(14, y + 1)))
	sources.append(SliceConstants.tile_id(PLANT_B.x, PLANT_B.y))

	return {
		"map_size": SliceConstants.MAP_SIZE,
		"tiles": tiles,
		"edges": edges,
		"power_sources": sources,
		"crisis_active": true,
		"crisis_sent": true,
	}


static func _tile(cell: Vector2i, owner: int, zone: int, tier: int, pollution: float) -> Dictionary:
	var tile := TileDelta.from_cell(cell.x, cell.y)
	tile.owner = owner
	tile.zone = zone
	tile.has_building = zone != SliceConstants.Zone.NONE
	tile.building_tier = tier
	tile.pollution = pollution
	tile.satisfaction = 0.75 if tile.has_building else 0.0
	return tile.to_dict()


static func _edge(a: Vector2i, b: Vector2i) -> Dictionary:
	var edge := WorldState.ordered_edge(a, b)
	edge.capacity = SliceConstants.CONGESTION_CAPACITY
	edge.congestion = 0.0
	return edge.to_dict()

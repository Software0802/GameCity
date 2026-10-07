class_name WorldState
extends RefCounted

## Authoritative MAP_SIZE×MAP_SIZE tiles, orthogonal edges, faction economies, and
## the M2B simulation: costs and tax, the demand triangle, satisfaction and tier
## growth, pollution, congestion, power capacity with brownout, and the grid storm.
## Pure data (no Node). apply() runs one command and leaves the world settled;
## sim_tick() advances growth and income once per SIM_TICK_SEC.
##
## The rules live in server/sim/ and this file orchestrates them:
##   SimEconomy     treasury, tax rate, counters, income, demand
##   PowerGrid      coverage, per-plant load, brownout
##   PollutionField incremental pollution field
##   RoadNetwork    edges, road access, congestion
##   GrowthModel    satisfaction and tier timers
## Per-tile scalars are mirrored in packed arrays so a tick never scans TileDelta
## objects; only tiles whose wire fields changed are touched and sent, once each.
##
## Spawn blocks are an example placement derived from SliceConstants.MAP_SIZE:
## faction A owns [0,SPAWN_SIZE)², faction B the mirrored corner.

const SimEconomy = preload("res://server/sim/sim_economy.gd")
const PowerGrid = preload("res://server/sim/power_grid.gd")
const PollutionField = preload("res://server/sim/pollution_field.gd")
const RoadNetwork = preload("res://server/sim/road_network.gd")
const GrowthModel = preload("res://server/sim/growth_model.gd")
const FieldQuant = preload("res://server/sim/field_quant.gd")

const SPAWN_SIZE := 8
const SPAWN_A := Vector2i(0, 0)
const SPAWN_B := Vector2i(
	SliceConstants.MAP_SIZE - SPAWN_SIZE, SliceConstants.MAP_SIZE - SPAWN_SIZE
)
const TILE_COUNT := SliceConstants.MAP_SIZE * SliceConstants.MAP_SIZE
const BLOCK_COUNT := SliceConstants.BLOCKS_PER_AXIS * SliceConstants.BLOCKS_PER_AXIS
const ORTHOGONAL: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)
]
## crisis_id of the one shared mid-round crisis.
const CRISIS_ID := "grid_storm"

## Set by server-core from --pace. Every duration is base × pace; every per-tick
## income is the per-sim-second rate ÷ pace. Values ≤ 0 fall back to PACE_DEFAULT.
var pace: float = SliceConstants.PACE_DEFAULT
## Set by server-core from --free-build: claims, edges, and plants cost nothing.
var free_build: bool = false
var crisis_active: bool = false
## Wall-clock second the active grid storm ends; 0 while none is active.
var crisis_ends_at_unix: int = 0

var _tiles: Array[TileDelta] = []
var _economy: SimEconomy = null
var _grid: PowerGrid = null
var _pollution: PollutionField = null
var _roads: RoadNetwork = null
var _growth: GrowthModel = null
## Packed mirrors of tile.owner / zone / building_tier for the growth pass.
var _owner_arr: PackedInt32Array = PackedInt32Array()
var _zone_arr: PackedInt32Array = PackedInt32Array()
var _tier_arr: PackedInt32Array = PackedInt32Array()
## Zoned tiles with a building: the only tiles growth visits.
var _active: Dictionary = {}
var _active_list: PackedInt32Array = PackedInt32Array()
var _active_stale: bool = true
## Owned tiles per faction per interest block (linear id), for interest_for().
var _owned_in_block: Array = []
## A grid storm was triggered this round. Persisted so a restart can tell; the
## schedule itself belongs to server-core (crisis_fired in the save envelope).
var _crisis_sent: bool = false
## The CrisisEvent for the current crisis_active value is waiting for the next tick.
var _crisis_pending: bool = false
var _last_tick: int = 0

## The edge dictionary (edge_key → EdgeDelta) lives in RoadNetwork; exposed here
## for snapshots and the save checks.
var _edges: Dictionary:
	get:
		return _roads.edges


func _init() -> void:
	_reset_runtime()
	for y in SliceConstants.MAP_SIZE:
		for x in SliceConstants.MAP_SIZE:
			_tiles.append(TileDelta.from_cell(x, y))
	_fill_spawn(SPAWN_A, SliceConstants.Owner.FACTION_A)
	_fill_spawn(SPAWN_B, SliceConstants.Owner.FACTION_B)


static func spawn_block(faction: int) -> InterestId:
	if faction == SliceConstants.Owner.FACTION_B:
		return InterestId.from_tile(SPAWN_B.x, SPAWN_B.y)
	return InterestId.from_tile(SPAWN_A.x, SPAWN_A.y)


static func edge_key(a: Vector2i, b: Vector2i) -> String:
	return RoadNetwork.key(a, b)


static func same_edge(a0: Vector2i, b0: Vector2i, a1: Vector2i, b1: Vector2i) -> bool:
	return edge_key(a0, b0) == edge_key(a1, b1)


static func ordered_edge(a: Vector2i, b: Vector2i) -> EdgeDelta:
	return RoadNetwork.ordered(a, b)


func tile_at(x: int, y: int) -> TileDelta:
	return _tiles[SliceConstants.tile_id(x, y)]


func find_edge(a: Vector2i, b: Vector2i) -> EdgeDelta:
	return _roads.find(a, b)


func has_power_source(x: int, y: int) -> bool:
	return _grid.has_plant(SliceConstants.tile_id(x, y))


# --- Economy and sim read-outs -------------------------------------------------


func treasury(faction: int) -> float:
	return _economy.ledger(faction).treasury


func tax_rate(faction: int) -> float:
	return _economy.ledger(faction).tax_rate


func population(faction: int) -> int:
	return _economy.ledger(faction).population


func jobs(faction: int) -> int:
	return _economy.ledger(faction).jobs()


func owned_count(faction: int) -> int:
	return _economy.ledger(faction).owned


## Price the next ClaimTile would cost this faction.
func claim_cost(faction: int) -> float:
	return _economy.claim_cost(faction)


## Unquantized satisfaction from the last tick (0 for tiles without a building).
func satisfaction_raw(x: int, y: int) -> float:
	return _growth.satisfaction_raw(SliceConstants.tile_id(x, y))


## Unquantized pollution field value.
func pollution_raw(x: int, y: int) -> float:
	return _pollution.value(SliceConstants.tile_id(x, y))


## Signed tier timer in sim seconds: > 0 toward a tier up, < 0 toward a tier down.
func tier_timer(x: int, y: int) -> float:
	return _growth.timer(SliceConstants.tile_id(x, y))


## Σ (tier + 1) over building tiles inside the plant's radius; 0 without a plant.
func plant_load(x: int, y: int) -> int:
	return _grid.plant_load(SliceConstants.tile_id(x, y))


## Current per-plant capacity (halved during the grid storm).
func plant_capacity() -> int:
	return _grid.capacity()


# --- Seams used by server-core -------------------------------------------------


## Both treasuries set to amount. server-core calls this right after
## WorldState.new() from --start-treasury on a new round; a restored save keeps
## its own treasuries and does not get this call.
func set_treasury_all(amount: float) -> void:
	_economy.set_treasury_all(amount)


## Grid storm on or off. Capacity changes at once; the CrisisEvent
## (kind grid_storm, ends_at_unix) goes out with the next sim_tick(). ends_at_unix
## defaults to now + CRISIS_DURATION_SEC; pass the scheduler's own end time to keep
## the banner countdown in step with when set_crisis(false) will be called.
func set_crisis(active: bool, ends_at_unix: int = 0) -> void:
	if active:
		var ends := ends_at_unix
		if ends <= 0:
			ends = int(Time.get_unix_time_from_system()) + SliceConstants.CRISIS_DURATION_SEC
		if crisis_active and ends == crisis_ends_at_unix:
			return
		crisis_active = true
		crisis_ends_at_unix = ends
		_crisis_sent = true
	else:
		if not crisis_active:
			return
		crisis_active = false
		crisis_ends_at_unix = 0
	_grid.set_crisis(active)
	_crisis_pending = true


## One FactionState per faction, every field filled. Route each to its own faction.
func faction_states() -> Array[FactionState]:
	var states: Array[FactionState] = []
	for faction in SliceConstants.FACTION_COUNT:
		var book := _economy.ledger(faction)
		var state := FactionState.new()
		state.faction = faction
		state.treasury = book.treasury
		state.income_per_sec = _economy.income_per_sec(faction, _pace())
		state.population = book.population
		state.jobs = book.jobs()
		state.technicians = 0
		state.tax_rate = book.tax_rate
		state.demand_r = _economy.demand_r(faction)
		state.demand_c = _economy.demand_c(faction)
		state.demand_i = _economy.demand_i(faction)
		state.power_capacity = _grid.faction_capacity(faction)
		state.power_load = _grid.faction_load(faction)
		states.append(state)
	return states


## Normalized ScoreTick for the last tick. pop = population, fiscal = treasury
## (design-v2: the fiscal score is the money at the end), control = owned tiles.
func score(seconds_remaining: int) -> ScoreTick:
	return _score(_last_tick, seconds_remaining)


# --- Save --------------------------------------------------------------------


## Save body for the "world" slot of the save envelope (docs/plans/m2-city-phase.md).
## Every value is JSON-serializable; payloads go through their to_dict().
## {
##   "map_size": int,                 must equal SliceConstants.MAP_SIZE to load
##   "tiles": [TileDelta.to_dict()],  only tiles that differ from TileDelta.from_cell(x, y), ascending id
##   "edges": [EdgeDelta.to_dict()],  ordered endpoints, ascending edge_key
##   "power_sources": [int],          tile ids, ascending
##   "crisis_active": bool,
##   "crisis_sent": bool,             a grid storm was triggered this round
##   "crisis_pending": bool,          a CrisisEvent still has to go out
##   "crisis_ends_at_unix": int,
##   "pace": float,
##   "factions": [{"faction": int, "treasury": float, "tax_rate": float}],  faction order
##   "tier_timers": [[id, toward_up_seconds, toward_down_seconds]],  non-zero only, ascending id
## }
## Counters, coverage, loads, pollution, and road access are derived from the tiles,
## edges, and plants on load.
func to_save_dict() -> Dictionary:
	var tiles: Array = []
	for tile in _tiles:
		if not _is_default_tile(tile):
			tiles.append(tile.to_dict())
	var edge_keys: Array = _roads.edges.keys()
	edge_keys.sort()
	var edges: Array = []
	for key in edge_keys:
		edges.append(_roads.edges[key].to_dict())
	return {
		"map_size": SliceConstants.MAP_SIZE,
		"tiles": tiles,
		"edges": edges,
		"power_sources": _grid.plant_ids_sorted(),
		"crisis_active": crisis_active,
		"crisis_sent": _crisis_sent,
		"crisis_pending": _crisis_pending,
		"crisis_ends_at_unix": crisis_ends_at_unix,
		"pace": float(pace),
		"factions": _economy.to_rows(),
		"tier_timers": _growth.timers_sparse(),
	}


## Static factory, not an instance method: a fresh WorldState pre-fills the spawn
## corners, so loading must first clear every tile to its default and then overlay
## the save. Returns null when the dict cannot be loaded (map_size differs from
## SliceConstants.MAP_SIZE). Rows that fail validation are skipped with a warning.
static func from_save_dict(data: Dictionary) -> WorldState:
	var size := int(data.get("map_size", SliceConstants.MAP_SIZE))
	if size != SliceConstants.MAP_SIZE:
		push_error("WorldState.from_save_dict: map_size %d, expected %d" % [size, SliceConstants.MAP_SIZE])
		return null
	var world := WorldState.new()
	world._restore(data)
	return world


func _restore(data: Dictionary) -> void:
	_reset_runtime()
	for i in _tiles.size():
		_tiles[i] = TileDelta.from_cell(i % SliceConstants.MAP_SIZE, int(i / SliceConstants.MAP_SIZE))
	var raw_tiles = data.get("tiles", [])
	if raw_tiles is Array:
		for raw in raw_tiles:
			if not (raw is Dictionary):
				continue
			var tile := TileDelta.from_dict(raw)
			if not SliceConstants.in_map(tile.x, tile.y):
				push_warning("WorldState._restore: tile (%d,%d) outside the map, skipped" % [tile.x, tile.y])
				continue
			var id := SliceConstants.tile_id(tile.x, tile.y)
			if tile.id != id:
				push_warning("WorldState._restore: tile (%d,%d) id %d, recomputed %d" % [tile.x, tile.y, tile.id, id])
				tile.id = id
			# Tiles are kept exactly as saved; only values that would index out of a
			# table are corrected.
			if not SliceConstants.is_zone(tile.zone):
				push_warning("WorldState._restore: tile (%d,%d) zone %d invalid, cleared" % [tile.x, tile.y, tile.zone])
				tile.zone = SliceConstants.Zone.NONE
			if tile.building_tier < SliceConstants.BUILDING_TIER_MIN or tile.building_tier > SliceConstants.BUILDING_TIER_MAX:
				push_warning("WorldState._restore: tile (%d,%d) tier %d out of range, clamped" % [tile.x, tile.y, tile.building_tier])
				tile.building_tier = clampi(tile.building_tier, SliceConstants.BUILDING_TIER_MIN, SliceConstants.BUILDING_TIER_MAX)
			_tiles[id] = tile
	# Buildings before edges: set_tier() then marks nothing dirty, and the saved
	# congestion values are trusted as they are.
	for tile in _tiles:
		_index_restored_tile(tile)
	var raw_edges = data.get("edges", [])
	if raw_edges is Array:
		for raw in raw_edges:
			if not (raw is Dictionary):
				continue
			var edge := EdgeDelta.from_dict(raw)
			if edge.removed:
				continue
			if (
				not SliceConstants.in_map(edge.a.x, edge.a.y)
				or not SliceConstants.in_map(edge.b.x, edge.b.y)
				or not EdgeDelta.is_orthogonal(edge.a, edge.b)
			):
				push_warning("WorldState._restore: edge %s-%s invalid, skipped" % [edge.a, edge.b])
				continue
			_roads.restore(edge)
	_roads.rebuild_tile_congestion()
	var raw_sources = data.get("power_sources", [])
	if raw_sources is Array:
		for raw in raw_sources:
			var id := int(raw)
			if id < 0 or id >= _tiles.size():
				push_warning("WorldState._restore: power source id %d outside the map, skipped" % id)
				continue
			var owner := _tiles[id].owner
			_grid.add_plant(id, owner)
			if SimEconomy.is_faction(owner):
				_economy.add_plant(owner, 1)
	crisis_active = bool(data.get("crisis_active", false))
	_crisis_sent = bool(data.get("crisis_sent", false))
	_crisis_pending = bool(data.get("crisis_pending", false))
	crisis_ends_at_unix = int(data.get("crisis_ends_at_unix", 0))
	if not crisis_active:
		crisis_ends_at_unix = 0
	_grid.set_crisis(crisis_active)
	var saved_pace := float(data.get("pace", SliceConstants.PACE_DEFAULT))
	if saved_pace > 0.0:
		pace = saved_pace
	else:
		push_warning("WorldState._restore: pace %s invalid, PACE_DEFAULT kept" % saved_pace)
	_economy.restore_rows(data.get("factions", []))
	_growth.restore_timers(data.get("tier_timers", []))
	# Derived state is now consistent with the saved tile flags; drop the bookkeeping
	# the rebuild produced instead of turning it into events.
	_grid.resolve()
	_pollution.take_dirty()


## Field-by-field against a fresh TileDelta.from_cell so new TileDelta fields are
## covered without listing them here.
func _is_default_tile(tile: TileDelta) -> bool:
	var actual := tile.to_dict()
	var blank := TileDelta.from_cell(tile.x, tile.y).to_dict()
	for key in actual:
		if actual[key] != blank.get(key):
			return false
	return true


# --- Commands ------------------------------------------------------------------


## Returns {reason, detail, events}. On failure, events is empty and state is unchanged.
## Eligibility is checked before funds; INSUFFICIENT_FUNDS never changes state.
func apply(faction: int, cmd: GameCommand) -> Dictionary:
	if cmd == null:
		return _fail(ReasonCode.Id.UNKNOWN_COMMAND, "null")
	var shape := cmd.validate_shape()
	if shape != ReasonCode.Id.OK:
		return _fail(shape, "")
	if not SimEconomy.is_faction(faction):
		return _fail(ReasonCode.Id.NOT_AUTHENTICATED, "no_faction")
	match cmd.kind:
		GameCommand.Kind.CLAIM_TILE:
			return _claim(faction, cmd)
		GameCommand.Kind.SET_ZONE:
			return _set_zone(faction, cmd)
		GameCommand.Kind.DEMOLISH_OWN:
			return _demolish(faction, cmd)
		GameCommand.Kind.PLACE_POWER:
			return _place_power(faction, cmd)
		GameCommand.Kind.REMOVE_POWER:
			return _remove_power(faction, cmd)
		GameCommand.Kind.ADD_EDGE:
			return _add_edge(faction, cmd)
		GameCommand.Kind.REMOVE_EDGE:
			return _remove_edge(faction, cmd)
		GameCommand.Kind.SET_TAX_RATE:
			return _set_tax_rate(faction, cmd)
		_:
			return _fail(ReasonCode.Id.UNKNOWN_COMMAND, "")


## One sim tick: growth (satisfaction, tier timers), then the settled consequences
## (power load and brownout, congestion, pollution), then income. Returns the
## events in this order: pending CrisisEvent, one TileDelta per changed tile,
## PowerAlert / CongestionAlert, ScoreTick. seconds_remaining is passed through to
## the ScoreTick; server-core supplies it from the round clock.
func sim_tick(tick_index: int, seconds_remaining: int = 0) -> Array:
	_last_tick = tick_index
	var dirty: Dictionary = {}
	var alerts: Array = []
	_grow(dirty)
	_settle(dirty, alerts)
	if not free_build:
		# Sandbox: no build costs and no upkeep; the treasury is frozen (no income either).
		_economy.tick(_pace())
	var events: Array = []
	if _crisis_pending:
		_crisis_pending = false
		events.append(ServerEvent.with_crisis_event(_crisis_event()))
	events.append_array(_tile_events(dirty))
	events.append_array(alerts)
	events.append(ServerEvent.with_score_tick(_score(tick_index, seconds_remaining)))
	return events


# --- Interest ------------------------------------------------------------------


## Own blocks, their orthogonal border blocks, and the camera block.
func interest_for(faction: int, camera: InterestId) -> Array[InterestId]:
	var picked: Dictionary = {}
	if SimEconomy.is_faction(faction):
		var counts: PackedInt32Array = _owned_in_block[faction]
		for linear in BLOCK_COUNT:
			if counts[linear] <= 0:
				continue
			var block := InterestId.from_linear(linear)
			picked[block.key()] = block
			for neighbor in _neighbor_blocks(block):
				picked[neighbor.key()] = neighbor
	if camera != null and _block_ok(camera):
		picked[camera.key()] = camera
	var result: Array[InterestId] = []
	for key in picked:
		result.append(picked[key])
	return result


func tiles_in_block(block: InterestId) -> Array[TileDelta]:
	var copies: Array[TileDelta] = []
	var x0 := block.block_x * SliceConstants.INTEREST_BLOCK
	var y0 := block.block_y * SliceConstants.INTEREST_BLOCK
	for y in SliceConstants.INTEREST_BLOCK:
		for x in SliceConstants.INTEREST_BLOCK:
			copies.append(_copy_tile(tile_at(x0 + x, y0 + y)))
	return copies


func edges_in_block(block: InterestId) -> Array[EdgeDelta]:
	var copies: Array[EdgeDelta] = []
	var want := block.key()
	var edges := _roads.edges
	for key in edges:
		var edge: EdgeDelta = edges[key]
		var block_a := InterestId.from_tile(edge.a.x, edge.a.y).key()
		var block_b := InterestId.from_tile(edge.b.x, edge.b.y).key()
		if block_a == want or block_b == want:
			copies.append(EdgeDelta.from_dict(edge.to_dict()))
	return copies


## Coarse view of one block: population (TIER_POP weighted), any residential tile
## without actual power, the crisis flag, mean pollution, any brownout.
func summary_for(block: InterestId) -> RegionSummary:
	var summary := RegionSummary.new()
	summary.interest = InterestId.new(block.block_x, block.block_y)
	var pop := 0
	var short_power := false
	var brownout := false
	var pollution_sum := 0.0
	var x0 := block.block_x * SliceConstants.INTEREST_BLOCK
	var y0 := block.block_y * SliceConstants.INTEREST_BLOCK
	for y in SliceConstants.INTEREST_BLOCK:
		for x in SliceConstants.INTEREST_BLOCK:
			var tile := tile_at(x0 + x, y0 + y)
			pollution_sum += tile.pollution
			if tile.brownout:
				brownout = true
			if tile.zone == SliceConstants.Zone.R and tile.has_building:
				pop += SliceConstants.TIER_POP[tile.building_tier]
				if not _grid.powered(tile.id):
					short_power = true
	summary.population = pop
	summary.power_alert = short_power
	summary.crisis = crisis_active
	summary.pollution_avg = pollution_sum / float(SliceConstants.INTEREST_BLOCK * SliceConstants.INTEREST_BLOCK)
	summary.brownout = brownout
	return summary


# --- Command handlers ----------------------------------------------------------


func _claim(faction: int, cmd: GameCommand) -> Dictionary:
	var tile := tile_at(cmd.tile_x, cmd.tile_y)
	if _is_opponent(faction, tile.owner):
		return _fail(ReasonCode.Id.OPPONENT_IMMUTABLE, "opponent_owner")
	if tile.owner != SliceConstants.Owner.NEUTRAL:
		return _fail(ReasonCode.Id.NOT_NEUTRAL, "not_neutral")
	if not _adjacent_to_faction(cmd.tile_x, cmd.tile_y, faction):
		return _fail(ReasonCode.Id.NOT_ADJACENT, "not_adjacent")
	var cost := _economy.claim_cost(faction)
	if not _economy.charge(faction, cost, free_build):
		return _fail(ReasonCode.Id.INSUFFICIENT_FUNDS, "cost_%d" % ceili(cost))
	_set_owner(tile, faction)
	return _ok([_tile_event(tile)])


## Zoning is free. A different zone starts a new tier-0 building; the same zone on
## a standing building changes nothing; the same zone on a demolished lot rebuilds.
func _set_zone(faction: int, cmd: GameCommand) -> Dictionary:
	var tile := tile_at(cmd.tile_x, cmd.tile_y)
	var gate := _require_self(faction, tile)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "zone")
	var same := tile.zone == cmd.zone
	if same and (cmd.zone == SliceConstants.Zone.NONE or tile.has_building):
		return _ok([_tile_event(tile)])
	var dirty: Dictionary = {}
	var alerts: Array = []
	_detach_building(tile)
	tile.zone = cmd.zone
	tile.has_building = cmd.zone != SliceConstants.Zone.NONE
	tile.building_tier = 0
	_growth.reset_timer(tile.id)
	_attach_building(tile)
	dirty[tile.id] = true
	_settle(dirty, alerts)
	var events := _tile_events(dirty)
	if cmd.zone == SliceConstants.Zone.R:
		events.append(_power_alert_event(tile))
	events.append_array(alerts)
	return _ok(events)


## Demolition is free and keeps the zone.
func _demolish(faction: int, cmd: GameCommand) -> Dictionary:
	var tile := tile_at(cmd.tile_x, cmd.tile_y)
	var gate := _require_self(faction, tile)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "demolish")
	if not tile.has_building:
		return _ok([_tile_event(tile)])
	var dirty: Dictionary = {}
	var alerts: Array = []
	_detach_building(tile)
	tile.has_building = false
	tile.building_tier = 0
	_attach_building(tile)
	dirty[tile.id] = true
	_settle(dirty, alerts)
	var events := _tile_events(dirty)
	events.append_array(alerts)
	return _ok(events)


func _place_power(faction: int, cmd: GameCommand) -> Dictionary:
	var tile := tile_at(cmd.tile_x, cmd.tile_y)
	var gate := _require_self(faction, tile)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "place_power")
	if _grid.has_plant(tile.id):
		return _ok([_tile_event(tile)])
	if not _economy.charge(faction, float(SliceConstants.COST_POWER), free_build):
		return _fail(ReasonCode.Id.INSUFFICIENT_FUNDS, "cost_%d" % SliceConstants.COST_POWER)
	var dirty: Dictionary = {tile.id: true}
	var alerts: Array = []
	var turned_on := _grid.add_plant(tile.id, faction)
	_economy.add_plant(faction, 1)
	_settle(dirty, alerts, turned_on)
	var events := _tile_events(dirty)
	events.append_array(alerts)
	return _ok(events)


## Removal is free, no refund.
func _remove_power(faction: int, cmd: GameCommand) -> Dictionary:
	var tile := tile_at(cmd.tile_x, cmd.tile_y)
	var gate := _require_self(faction, tile)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "remove_power")
	if not _grid.has_plant(tile.id):
		return _ok([_tile_event(tile)])
	var dirty: Dictionary = {tile.id: true}
	var alerts: Array = []
	var changed := _grid.remove_plant(tile.id)
	_economy.add_plant(faction, -1)
	_settle(dirty, alerts, changed)
	var events := _tile_events(dirty)
	events.append_array(alerts)
	return _ok(events)


func _add_edge(faction: int, cmd: GameCommand) -> Dictionary:
	var gate := _edge_owner_gate(faction, cmd.edge_a, cmd.edge_b)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "endpoint_owner")
	var existing := _roads.find(cmd.edge_a, cmd.edge_b)
	if existing != null:
		return _ok([ServerEvent.with_edge_delta(EdgeDelta.from_dict(existing.to_dict()))])
	if not _economy.charge(faction, float(SliceConstants.COST_EDGE), free_build):
		return _fail(ReasonCode.Id.INSUFFICIENT_FUNDS, "cost_%d" % SliceConstants.COST_EDGE)
	var edge := _roads.add(cmd.edge_a, cmd.edge_b)
	var dirty: Dictionary = {}
	var alerts: Array = []
	_settle(dirty, alerts)
	var events: Array = [ServerEvent.with_edge_delta(EdgeDelta.from_dict(edge.to_dict()))]
	events.append_array(_tile_events(dirty))
	events.append_array(alerts)
	return _ok(events)


## Removal is free, no refund.
func _remove_edge(faction: int, cmd: GameCommand) -> Dictionary:
	var gate := _edge_owner_gate(faction, cmd.edge_a, cmd.edge_b)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "endpoint_owner")
	var ordered := ordered_edge(cmd.edge_a, cmd.edge_b)
	if not _roads.remove(ordered.a, ordered.b):
		return _fail(ReasonCode.Id.EDGE_RULE, "missing_edge")
	var dirty: Dictionary = {}
	var alerts: Array = []
	_settle(dirty, alerts)
	var events: Array = [ServerEvent.with_edge_delta(EdgeDelta.make_removed(ordered.a, ordered.b))]
	events.append_array(_tile_events(dirty))
	events.append_array(alerts)
	return _ok(events)


## Range already checked by validate_shape(). Takes effect on the next tick's
## income and satisfaction; the FactionState carries the new rate.
func _set_tax_rate(faction: int, cmd: GameCommand) -> Dictionary:
	_economy.ledger(faction).tax_rate = cmd.rate
	return _ok([])


# --- Structural bookkeeping ----------------------------------------------------


func _reset_runtime() -> void:
	_economy = SimEconomy.new()
	_grid = PowerGrid.new()
	_pollution = PollutionField.new()
	_roads = RoadNetwork.new()
	_growth = GrowthModel.new()
	_owner_arr.resize(TILE_COUNT)
	_owner_arr.fill(SliceConstants.Owner.NEUTRAL)
	_zone_arr.resize(TILE_COUNT)
	_zone_arr.fill(SliceConstants.Zone.NONE)
	_tier_arr.resize(TILE_COUNT)
	_tier_arr.fill(0)
	_active.clear()
	_active_list = PackedInt32Array()
	_active_stale = true
	_owned_in_block = []
	for _faction in SliceConstants.FACTION_COUNT:
		var counts := PackedInt32Array()
		counts.resize(BLOCK_COUNT)
		counts.fill(0)
		_owned_in_block.append(counts)
	crisis_active = false
	crisis_ends_at_unix = 0
	_crisis_sent = false
	_crisis_pending = false
	_last_tick = 0


func _fill_spawn(origin: Vector2i, owner: int) -> void:
	for y in SPAWN_SIZE:
		for x in SPAWN_SIZE:
			_set_owner(tile_at(origin.x + x, origin.y + y), owner)


## Owner change with every counter that depends on it. A building moves its
## population or jobs to the new owner (not reachable in M2, kept correct anyway).
func _set_owner(tile: TileDelta, owner: int) -> void:
	var previous := tile.owner
	if previous == owner:
		return
	var linear := InterestId.from_tile(tile.x, tile.y).linear_id()
	var is_building := tile.has_building and tile.zone != SliceConstants.Zone.NONE
	if SimEconomy.is_faction(previous):
		_economy.add_owned(previous, -1)
		_owned_in_block[previous][linear] -= 1
		if is_building:
			_economy.add_building(previous, tile.zone, tile.building_tier, -1)
	tile.owner = owner
	_owner_arr[tile.id] = owner
	if SimEconomy.is_faction(owner):
		_economy.add_owned(owner, 1)
		_owned_in_block[owner][linear] += 1
		if is_building:
			_economy.add_building(owner, tile.zone, tile.building_tier, 1)


## Call before changing zone / has_building / building_tier.
func _detach_building(tile: TileDelta) -> void:
	if tile.has_building and tile.zone != SliceConstants.Zone.NONE:
		_economy.add_building(tile.owner, tile.zone, tile.building_tier, -1)


## Call after changing zone / has_building / building_tier: counters, the sim
## modules' per-tile inputs, and the active set follow the tile's new fields.
func _attach_building(tile: TileDelta) -> void:
	var id := tile.id
	var is_building := tile.has_building and tile.zone != SliceConstants.Zone.NONE
	var tier := tile.building_tier if is_building else 0
	if is_building:
		_economy.add_building(tile.owner, tile.zone, tier, 1)
	_zone_arr[id] = tile.zone
	_tier_arr[id] = tier
	_grid.set_weight(id, tier + 1 if is_building else 0)
	var emits := is_building and tile.zone == SliceConstants.Zone.I
	_pollution.set_emission(id, tier + 1 if emits else 0)
	_roads.set_tier(id, tier)
	if is_building:
		if not _active.has(id):
			_active[id] = true
			_active_stale = true
	else:
		if _active.erase(id):
			_active_stale = true
		_growth.deactivate(id)
		tile.satisfaction = 0.0


## Restore path: counters and module inputs from a tile exactly as saved.
func _index_restored_tile(tile: TileDelta) -> void:
	var id := tile.id
	_owner_arr[id] = tile.owner
	if SimEconomy.is_faction(tile.owner):
		_economy.add_owned(tile.owner, 1)
		_owned_in_block[tile.owner][InterestId.from_tile(tile.x, tile.y).linear_id()] += 1
	var is_building := tile.has_building and tile.zone != SliceConstants.Zone.NONE
	var tier := tile.building_tier if is_building else 0
	if is_building:
		_economy.add_building(tile.owner, tile.zone, tier, 1)
		_active[id] = true
		_active_stale = true
	_zone_arr[id] = tile.zone
	_tier_arr[id] = tier
	_grid.set_weight(id, tier + 1 if is_building else 0)
	var emits := is_building and tile.zone == SliceConstants.Zone.I
	_pollution.set_emission(id, tier + 1 if emits else 0)
	_roads.set_tier(id, tier)
	if is_building:
		_growth.set_satisfaction_q(id, tile.satisfaction)


## Tier change from growth: counters and module inputs follow.
func _set_tier(id: int, tier: int, dirty: Dictionary) -> void:
	var tile := _tiles[id]
	_detach_building(tile)
	tile.building_tier = tier
	_attach_building(tile)
	dirty[id] = true


# --- Tick phases ---------------------------------------------------------------


## Growth pass over the active tiles; applies the tier changes it produces.
func _grow(dirty: Dictionary) -> void:
	if _active_stale:
		var ids: Array = _active.keys()
		ids.sort()
		_active_list = PackedInt32Array(ids)
		_active_stale = false
	if _active_list.is_empty():
		return
	var gates: Array = []
	var penalties := PackedFloat32Array()
	for faction in SliceConstants.FACTION_COUNT:
		var row := PackedFloat32Array()
		row.resize(SliceConstants.Zone.size())
		row.fill(0.0)
		row[SliceConstants.Zone.R] = GrowthModel.gate_for(_economy.demand_r(faction))
		row[SliceConstants.Zone.C] = GrowthModel.gate_for(_economy.demand_c(faction))
		row[SliceConstants.Zone.I] = GrowthModel.gate_for(_economy.demand_i(faction))
		gates.append(row)
		penalties.append(GrowthModel.tax_penalty(_economy.ledger(faction).tax_rate))
	var result := _growth.run(
		_active_list,
		_owner_arr,
		_zone_arr,
		_tier_arr,
		_roads.degree_array(),
		_grid.cover_array(),
		_grid.dark_array(),
		_roads.tile_congestion_array(),
		_pollution.mass_array(),
		_pollution.weight_total,
		gates,
		penalties,
		GrowthModel.sim_seconds_per_tick(_pace())
	)
	for id in result["sat_changed"]:
		_tiles[id].satisfaction = _growth.satisfaction_q(id)
		dirty[id] = true
	for change in result["tier_changes"]:
		_set_tier(change[0], change[1], dirty)


## Resolves everything the structural changes since the last call left dirty:
## plant loads and brownout (plus the coverage changes handed in), congestion,
## pollution. Fills dirty with the tiles whose wire fields moved and alerts with
## the PowerAlert / CongestionAlert events.
func _settle(dirty: Dictionary, alerts: Array, power_touched: PackedInt32Array = PackedInt32Array()) -> void:
	var resolved := _grid.resolve()
	var touched: Dictionary = {}
	for id in power_touched:
		touched[id] = true
	for id in resolved["tiles"]:
		touched[id] = true
	for id in touched:
		_sync_power_tile(id, dirty, alerts)
	for entry in resolved["alerts"]:
		alerts.append(_plant_alert_event(entry[0], entry[1]))
	for edge in _roads.resolve():
		alerts.append(_congestion_alert_event(edge))
	for id in _pollution.take_dirty():
		var tile := _tiles[id]
		var quantized := _pollution.quantized(id)
		if tile.pollution != quantized:
			tile.pollution = quantized
			dirty[id] = true


## Copies the grid's view of one tile into its TileDelta. A residential tile whose
## actual power (covered and not brownout) flipped also gets a PowerAlert.
func _sync_power_tile(id: int, dirty: Dictionary, alerts: Array) -> void:
	var tile := _tiles[id]
	var covered := _grid.covered(id)
	var dark := _grid.brownout(id)
	if tile.power_covered == covered and tile.brownout == dark:
		return
	var was_powered := tile.power_covered and not tile.brownout
	tile.power_covered = covered
	tile.brownout = dark
	dirty[id] = true
	if tile.zone == SliceConstants.Zone.R and was_powered != (covered and not dark):
		alerts.append(_power_alert_event(tile))


# --- Score -----------------------------------------------------------------


## Each normalized term is ScoreTick.share(own, other): max(0, value), then
## own / (own + other), 0.5 when both are 0. Raw terms: population, treasury,
## owned tiles.
func _score(tick_index: int, seconds_remaining: int) -> ScoreTick:
	var tick := ScoreTick.new()
	tick.tick_index = tick_index
	tick.seconds_remaining = seconds_remaining
	var raw: Dictionary = {}
	for faction in [SliceConstants.Owner.FACTION_A, SliceConstants.Owner.FACTION_B]:
		var book := _economy.ledger(faction)
		raw[faction] = {
			"pop": float(book.population),
			"fiscal": book.treasury,
			"control": float(book.owned),
		}
	for faction in [SliceConstants.Owner.FACTION_A, SliceConstants.Owner.FACTION_B]:
		var other := SliceConstants.Owner.FACTION_B
		if faction == SliceConstants.Owner.FACTION_B:
			other = SliceConstants.Owner.FACTION_A
		var mine: Dictionary = raw[faction]
		var theirs: Dictionary = raw[other]
		var line := ScoreTick.FactionScore.new()
		line.faction = faction
		line.pop_raw = mine["pop"]
		line.fiscal_raw = mine["fiscal"]
		line.control_raw = mine["control"]
		line.pop = ScoreTick.share(mine["pop"], theirs["pop"])
		line.fiscal = ScoreTick.share(mine["fiscal"], theirs["fiscal"])
		line.control = ScoreTick.share(mine["control"], theirs["control"])
		tick.factions.append(line)
	return tick


# --- Gates and helpers ---------------------------------------------------------


func _edge_owner_gate(faction: int, a: Vector2i, b: Vector2i) -> int:
	var owner_a := tile_at(a.x, a.y).owner
	var owner_b := tile_at(b.x, b.y).owner
	if _is_opponent(faction, owner_a) or _is_opponent(faction, owner_b):
		return ReasonCode.Id.OPPONENT_IMMUTABLE
	if owner_a != faction or owner_b != faction:
		return ReasonCode.Id.EDGE_RULE
	return ReasonCode.Id.OK


func _require_self(faction: int, tile: TileDelta) -> int:
	if _is_opponent(faction, tile.owner):
		return ReasonCode.Id.OPPONENT_IMMUTABLE
	if tile.owner != faction:
		return ReasonCode.Id.NOT_OWNER
	return ReasonCode.Id.OK


func _is_opponent(faction: int, owner: int) -> bool:
	return owner != SliceConstants.Owner.NEUTRAL and owner != faction


func _adjacent_to_faction(x: int, y: int, faction: int) -> bool:
	for step in ORTHOGONAL:
		var nx := x + step.x
		var ny := y + step.y
		if not SliceConstants.in_map(nx, ny):
			continue
		if tile_at(nx, ny).owner == faction:
			return true
	return false


func _pace() -> float:
	if pace > 0.0:
		return pace
	return SliceConstants.PACE_DEFAULT


func _neighbor_blocks(block: InterestId) -> Array[InterestId]:
	var found: Array[InterestId] = []
	for step in ORTHOGONAL:
		var nx := block.block_x + step.x
		var ny := block.block_y + step.y
		if not _block_xy_ok(nx, ny):
			continue
		found.append(InterestId.new(nx, ny))
	return found


func _block_ok(block: InterestId) -> bool:
	return _block_xy_ok(block.block_x, block.block_y)


func _block_xy_ok(block_x: int, block_y: int) -> bool:
	return (
		block_x >= 0
		and block_y >= 0
		and block_x < SliceConstants.BLOCKS_PER_AXIS
		and block_y < SliceConstants.BLOCKS_PER_AXIS
	)


# --- Events ----------------------------------------------------------------


## One TileDelta per dirty id, in insertion order (the command's own tile first).
func _tile_events(dirty: Dictionary) -> Array:
	var events: Array = []
	for id in dirty:
		events.append(_tile_event(_tiles[id]))
	return events


func _tile_event(tile: TileDelta) -> ServerEvent:
	return ServerEvent.with_tile_delta(_copy_tile(tile))


func _power_alert_event(tile: TileDelta) -> ServerEvent:
	var alert := PowerAlert.new()
	alert.x = tile.x
	alert.y = tile.y
	alert.power_covered = tile.power_covered
	alert.shortage = tile.zone == SliceConstants.Zone.R and not (tile.power_covered and not tile.brownout)
	alert.brownout = tile.brownout
	return ServerEvent.with_power_alert(alert)


## One alert per plant whose over-capacity state flipped, at the plant's tile.
func _plant_alert_event(plant_id: int, over: bool) -> ServerEvent:
	var tile := _tiles[plant_id]
	var alert := PowerAlert.new()
	alert.x = tile.x
	alert.y = tile.y
	alert.power_covered = true
	alert.shortage = tile.zone == SliceConstants.Zone.R and over
	alert.brownout = over
	return ServerEvent.with_power_alert(alert)


func _congestion_alert_event(edge: EdgeDelta) -> ServerEvent:
	var alert := CongestionAlert.new()
	alert.a = edge.a
	alert.b = edge.b
	alert.congestion = edge.congestion
	return ServerEvent.with_congestion_alert(alert)


func _crisis_event() -> CrisisEvent:
	var crisis := CrisisEvent.new()
	crisis.crisis_id = CRISIS_ID
	crisis.kind = CrisisEvent.KIND_GRID_STORM
	crisis.active = crisis_active
	crisis.detail = "shared"
	crisis.ends_at_unix = crisis_ends_at_unix
	return crisis


func _copy_tile(tile: TileDelta) -> TileDelta:
	var copy := TileDelta.new()
	copy.id = tile.id
	copy.x = tile.x
	copy.y = tile.y
	copy.owner = tile.owner
	copy.zone = tile.zone
	copy.has_building = tile.has_building
	copy.building_tier = tile.building_tier
	copy.power_covered = tile.power_covered
	copy.satisfaction = tile.satisfaction
	copy.pollution = tile.pollution
	copy.brownout = tile.brownout
	return copy


func _ok(events: Array) -> Dictionary:
	return {"reason": ReasonCode.Id.OK, "detail": "", "events": events}


func _fail(reason: int, detail: String) -> Dictionary:
	return {"reason": reason, "detail": detail, "events": []}

class_name WorldState
extends RefCounted

## Authoritative 64×64 tiles, orthogonal edges, and permission checks.
## Pure data (no Node). Listen-host and the headless scene both use this.
## Spawn blocks are an example placement, not a locked coordinate:
## faction A owns tiles [0,8) × [0,8); faction B owns [56,64) × [56,64).
## Population, fiscal, and congestion numbers are placeholders.

const SPAWN_SIZE := 8
const SPAWN_A := Vector2i(0, 0)
const SPAWN_B := Vector2i(56, 56)
const EDGE_CAPACITY := 10
const CRISIS_TICK := 30
const CONGESTION_WHEN_ZONED := 0.35
const ORTHOGONAL: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)
]

var crisis_active: bool = false

var _tiles: Array[TileDelta] = []
var _edges: Dictionary = {}
var _power_sources: Dictionary = {}
var _crisis_sent: bool = false


func _init() -> void:
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
	var ordered := ordered_edge(a, b)
	return "%d,%d:%d,%d" % [ordered.a.x, ordered.a.y, ordered.b.x, ordered.b.y]


static func same_edge(a0: Vector2i, b0: Vector2i, a1: Vector2i, b1: Vector2i) -> bool:
	return edge_key(a0, b0) == edge_key(a1, b1)


static func ordered_edge(a: Vector2i, b: Vector2i) -> EdgeDelta:
	var edge := EdgeDelta.new()
	if a.x < b.x or (a.x == b.x and a.y <= b.y):
		edge.a = a
		edge.b = b
	else:
		edge.a = b
		edge.b = a
	return edge


func tile_at(x: int, y: int) -> TileDelta:
	return _tiles[SliceConstants.tile_id(x, y)]


func find_edge(a: Vector2i, b: Vector2i) -> EdgeDelta:
	var key := edge_key(a, b)
	if not _edges.has(key):
		return null
	return _edges[key]


func has_power_source(x: int, y: int) -> bool:
	return _power_sources.has(SliceConstants.tile_id(x, y))


## Returns {reason, detail, events}. On failure, events is empty and state is unchanged.
func apply(faction: int, cmd: GameCommand) -> Dictionary:
	if cmd == null:
		return _fail(ReasonCode.Id.UNKNOWN_COMMAND, "null")
	var shape := cmd.validate_shape()
	if shape != ReasonCode.Id.OK:
		return _fail(shape, "")
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
		_:
			return _fail(ReasonCode.Id.UNKNOWN_COMMAND, "")


func sim_tick(tick_index: int) -> Array:
	var events: Array = []
	events.append_array(_sync_power_events())
	events.append_array(_sync_congestion_events())
	if tick_index >= CRISIS_TICK and not _crisis_sent:
		_crisis_sent = true
		crisis_active = true
		var crisis := CrisisEvent.new()
		crisis.crisis_id = "mid_match"
		crisis.active = true
		crisis.detail = "shared"
		events.append(ServerEvent.with_crisis_event(crisis))
	events.append(ServerEvent.with_score_tick(_score(tick_index)))
	return events


## Own blocks, their orthogonal border blocks, and the camera block.
func interest_for(faction: int, camera: InterestId) -> Array[InterestId]:
	var picked: Dictionary = {}
	for tile in _tiles:
		if tile.owner != faction:
			continue
		var block := InterestId.from_tile(tile.x, tile.y)
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
	for key in _edges:
		var edge: EdgeDelta = _edges[key]
		var block_a := InterestId.from_tile(edge.a.x, edge.a.y).key()
		var block_b := InterestId.from_tile(edge.b.x, edge.b.y).key()
		if block_a == want or block_b == want:
			copies.append(EdgeDelta.from_dict(edge.to_dict()))
	return copies


func summary_for(block: InterestId) -> RegionSummary:
	var summary := RegionSummary.new()
	summary.interest = InterestId.new(block.block_x, block.block_y)
	var pop := 0
	var short_power := false
	var x0 := block.block_x * SliceConstants.INTEREST_BLOCK
	var y0 := block.block_y * SliceConstants.INTEREST_BLOCK
	for y in SliceConstants.INTEREST_BLOCK:
		for x in SliceConstants.INTEREST_BLOCK:
			var tile := tile_at(x0 + x, y0 + y)
			if _tile_has_population(tile):
				pop += 1
			if tile.zone == SliceConstants.Zone.R and not tile.power_covered:
				short_power = true
	summary.population = pop
	summary.power_alert = short_power
	summary.crisis = crisis_active
	return summary


func _claim(faction: int, cmd: GameCommand) -> Dictionary:
	var tile := tile_at(cmd.tile_x, cmd.tile_y)
	if _is_opponent(faction, tile.owner):
		return _fail(ReasonCode.Id.OPPONENT_IMMUTABLE, "opponent_owner")
	if tile.owner != SliceConstants.Owner.NEUTRAL:
		return _fail(ReasonCode.Id.NOT_NEUTRAL, "not_neutral")
	if not _adjacent_to_faction(cmd.tile_x, cmd.tile_y, faction):
		return _fail(ReasonCode.Id.NOT_ADJACENT, "not_adjacent")
	tile.owner = faction
	return _ok([_tile_event(tile)])


func _set_zone(faction: int, cmd: GameCommand) -> Dictionary:
	var tile := tile_at(cmd.tile_x, cmd.tile_y)
	var gate := _require_self(faction, tile)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "zone")
	tile.zone = cmd.zone
	if cmd.zone == SliceConstants.Zone.NONE:
		tile.has_building = false
		tile.building_tier = 0
	else:
		tile.has_building = true
	var events: Array = [_tile_event(tile)]
	if cmd.zone == SliceConstants.Zone.R:
		events.append(_power_alert_event(tile))
	return _ok(events)


func _demolish(faction: int, cmd: GameCommand) -> Dictionary:
	var tile := tile_at(cmd.tile_x, cmd.tile_y)
	var gate := _require_self(faction, tile)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "demolish")
	tile.has_building = false
	tile.building_tier = 0
	return _ok([_tile_event(tile)])


func _place_power(faction: int, cmd: GameCommand) -> Dictionary:
	var tile := tile_at(cmd.tile_x, cmd.tile_y)
	var gate := _require_self(faction, tile)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "place_power")
	_power_sources[tile.id] = true
	return _ok(_events_after_power_change(tile))


func _remove_power(faction: int, cmd: GameCommand) -> Dictionary:
	var tile := tile_at(cmd.tile_x, cmd.tile_y)
	var gate := _require_self(faction, tile)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "remove_power")
	_power_sources.erase(tile.id)
	return _ok(_events_after_power_change(tile))


func _add_edge(faction: int, cmd: GameCommand) -> Dictionary:
	var gate := _edge_owner_gate(faction, cmd.edge_a, cmd.edge_b)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "endpoint_owner")
	var ordered := ordered_edge(cmd.edge_a, cmd.edge_b)
	var key := edge_key(ordered.a, ordered.b)
	if not _edges.has(key):
		ordered.capacity = EDGE_CAPACITY
		ordered.congestion = 0.0
		ordered.removed = false
		_edges[key] = ordered
	return _ok([ServerEvent.with_edge_delta(EdgeDelta.from_dict(_edges[key].to_dict()))])


func _remove_edge(faction: int, cmd: GameCommand) -> Dictionary:
	var gate := _edge_owner_gate(faction, cmd.edge_a, cmd.edge_b)
	if gate != ReasonCode.Id.OK:
		return _fail(gate, "endpoint_owner")
	var ordered := ordered_edge(cmd.edge_a, cmd.edge_b)
	var key := edge_key(ordered.a, ordered.b)
	if not _edges.has(key):
		return _fail(ReasonCode.Id.EDGE_RULE, "missing_edge")
	_edges.erase(key)
	return _ok([ServerEvent.with_edge_delta(EdgeDelta.make_removed(ordered.a, ordered.b))])


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


func _events_after_power_change(focus: TileDelta) -> Array:
	var events := _sync_power_events()
	for event in events:
		if event.kind == ServerEvent.Kind.TILE_DELTA and event.tile_delta.id == focus.id:
			return events
	events.append(_tile_event(focus))
	return events


func _sync_power_events() -> Array:
	var covered := _covered_ids()
	var events: Array = []
	for tile in _tiles:
		var on: bool = covered.has(tile.id)
		if tile.power_covered == on:
			continue
		tile.power_covered = on
		events.append(_tile_event(tile))
		if tile.zone == SliceConstants.Zone.R:
			events.append(_power_alert_event(tile))
	return events


func _covered_ids() -> Dictionary:
	var covered: Dictionary = {}
	var radius := SliceConstants.POWER_RADIUS_SUGGESTED
	for raw_id in _power_sources.keys():
		var origin := _tiles[int(raw_id)]
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if absi(dx) + absi(dy) > radius:
					continue
				var nx := origin.x + dx
				var ny := origin.y + dy
				if SliceConstants.in_map(nx, ny):
					covered[SliceConstants.tile_id(nx, ny)] = true
	return covered


func _sync_congestion_events() -> Array:
	var events: Array = []
	for key in _edges:
		var edge: EdgeDelta = _edges[key]
		var next := _congestion_for(edge)
		if is_equal_approx(edge.congestion, next):
			continue
		edge.congestion = next
		var alert := CongestionAlert.new()
		alert.a = edge.a
		alert.b = edge.b
		alert.congestion = next
		events.append(ServerEvent.with_congestion_alert(alert))
	return events


func _congestion_for(edge: EdgeDelta) -> float:
	var zone_a := tile_at(edge.a.x, edge.a.y).zone
	var zone_b := tile_at(edge.b.x, edge.b.y).zone
	if zone_a == SliceConstants.Zone.NONE or zone_b == SliceConstants.Zone.NONE:
		return 0.0
	return CONGESTION_WHEN_ZONED


func _score(tick_index: int) -> ScoreTick:
	var tick := ScoreTick.new()
	tick.tick_index = tick_index
	for faction in [SliceConstants.Owner.FACTION_A, SliceConstants.Owner.FACTION_B]:
		var line := ScoreTick.FactionScore.new()
		line.faction = faction
		line.pop = float(_population(faction))
		line.fiscal = line.pop * 2.0 - float(_power_source_count(faction))
		line.control = float(_owned_count(faction))
		tick.factions.append(line)
	return tick


func _population(faction: int) -> int:
	var count := 0
	for tile in _tiles:
		if tile.owner == faction and _tile_has_population(tile):
			count += 1
	return count


func _tile_has_population(tile: TileDelta) -> bool:
	return (
		tile.zone == SliceConstants.Zone.R
		and tile.has_building
		and tile.power_covered
		and _has_road(tile.x, tile.y)
	)


func _has_road(x: int, y: int) -> bool:
	var here := Vector2i(x, y)
	for step in ORTHOGONAL:
		var nxt: Vector2i = here + step
		if not SliceConstants.in_map(nxt.x, nxt.y):
			continue
		if _edges.has(edge_key(here, nxt)):
			return true
	return false


func _power_source_count(faction: int) -> int:
	var count := 0
	for raw_id in _power_sources.keys():
		if _tiles[int(raw_id)].owner == faction:
			count += 1
	return count


func _owned_count(faction: int) -> int:
	var count := 0
	for tile in _tiles:
		if tile.owner == faction:
			count += 1
	return count


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


func _fill_spawn(origin: Vector2i, owner: int) -> void:
	for y in SPAWN_SIZE:
		for x in SPAWN_SIZE:
			tile_at(origin.x + x, origin.y + y).owner = owner


func _tile_event(tile: TileDelta) -> ServerEvent:
	return ServerEvent.with_tile_delta(_copy_tile(tile))


func _power_alert_event(tile: TileDelta) -> ServerEvent:
	var alert := PowerAlert.new()
	alert.x = tile.x
	alert.y = tile.y
	alert.power_covered = tile.power_covered
	alert.shortage = tile.zone == SliceConstants.Zone.R and not tile.power_covered
	return ServerEvent.with_power_alert(alert)


func _copy_tile(tile: TileDelta) -> TileDelta:
	return TileDelta.from_dict(tile.to_dict())


func _ok(events: Array) -> Dictionary:
	return {"reason": ReasonCode.Id.OK, "detail": "", "events": events}


func _fail(reason: int, detail: String) -> Dictionary:
	return {"reason": reason, "detail": detail, "events": []}

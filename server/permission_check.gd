extends SceneTree

## Headless permission + parse check. No second peer.
##   godot --headless --path . -s res://server/permission_check.gd

const WorldStateScript = preload("res://server/world_state.gd")


func _initialize() -> void:
	var errors: Array[String] = []
	_check_parse(errors)
	_check_permissions(errors)
	_check_power_tick_interest(errors)
	_check_client_interest_cache(errors)
	if errors.is_empty():
		print("PERMISSION_OK")
		quit(0)
	else:
		for err in errors:
			print("PERMISSION_FAIL %s" % err)
		quit(1)


func _check_parse(errors: Array[String]) -> void:
	var claim := GameCommand.claim_tile(3, 4)
	var claim_back := GameCommand.from_dict(claim.to_dict())
	_expect(errors, claim_back.kind == GameCommand.Kind.CLAIM_TILE and claim_back.tile_x == 3 and claim_back.tile_y == 4, "claim roundtrip")
	var edge := GameCommand.add_edge(Vector2i(1, 2), Vector2i(1, 3))
	var edge_back := GameCommand.from_dict(edge.to_dict())
	_expect(errors, edge_back.edge_a == Vector2i(1, 2) and edge_back.edge_b == Vector2i(1, 3), "edge roundtrip")
	_expect(errors, GameCommand.set_zone(0, 0, 99).validate_shape() == ReasonCode.Id.INVALID_ZONE, "invalid zone shape")
	_expect(errors, GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 1)).validate_shape() == ReasonCode.Id.NOT_ORTHOGONAL, "diagonal shape")
	var reject := CommandReject.new(claim, ReasonCode.Id.NOT_OWNER, "zone")
	var reject_back := CommandReject.from_dict(reject.to_dict())
	_expect(errors, reject_back.reason == ReasonCode.Id.NOT_OWNER and reject_back.command.tile_x == 3, "reject roundtrip")
	var tile := TileDelta.from_cell(2, 5)
	tile.owner = SliceConstants.Owner.FACTION_A
	var event := ServerEvent.from_dict(ServerEvent.with_tile_delta(tile).to_dict())
	_expect(errors, event.kind == ServerEvent.Kind.TILE_DELTA and event.tile_delta.x == 2 and event.tile_delta.owner == SliceConstants.Owner.FACTION_A, "tile event roundtrip")


func _check_permissions(errors: Array[String]) -> void:
	var world = WorldStateScript.new()
	var faction_a := SliceConstants.Owner.FACTION_A
	var faction_b := SliceConstants.Owner.FACTION_B

	var claim := world.apply(faction_a, GameCommand.claim_tile(8, 0))
	_expect(errors, claim["reason"] == ReasonCode.Id.OK, "legal claim reason")
	_expect(errors, world.tile_at(8, 0).owner == faction_a, "legal claim owner")
	_expect(errors, claim["events"].size() >= 1 and claim["events"][0].kind == ServerEvent.Kind.TILE_DELTA, "legal claim delta")
	_expect(errors, claim["events"][0].tile_delta.owner == faction_a and claim["events"][0].tile_delta.x == 8, "legal claim snapshot")

	var again := world.apply(faction_a, GameCommand.claim_tile(0, 0))
	_expect(errors, again["reason"] == ReasonCode.Id.NOT_NEUTRAL and again["events"].is_empty(), "claim own spawn")
	_expect(errors, world.tile_at(0, 0).owner == faction_a, "spawn unchanged")

	var far := world.apply(faction_a, GameCommand.claim_tile(20, 20))
	_expect(errors, far["reason"] == ReasonCode.Id.NOT_ADJACENT, "claim not adjacent")
	_expect(errors, world.tile_at(20, 20).owner == SliceConstants.Owner.NEUTRAL, "far tile stays neutral")

	var steal := world.apply(faction_b, GameCommand.claim_tile(8, 0))
	_expect(errors, steal["reason"] == ReasonCode.Id.OPPONENT_IMMUTABLE and steal["events"].is_empty(), "steal claim")
	_expect(errors, world.tile_at(8, 0).owner == faction_a, "stolen tile unchanged")

	var bounds := world.apply(faction_a, GameCommand.claim_tile(64, 0))
	_expect(errors, bounds["reason"] == ReasonCode.Id.OUT_OF_BOUNDS, "claim out of bounds")

	var zone_neutral := world.apply(faction_a, GameCommand.set_zone(20, 20, SliceConstants.Zone.R))
	_expect(errors, zone_neutral["reason"] == ReasonCode.Id.NOT_OWNER, "zone on neutral")

	var zone_enemy := world.apply(faction_a, GameCommand.set_zone(56, 56, SliceConstants.Zone.I))
	_expect(errors, zone_enemy["reason"] == ReasonCode.Id.OPPONENT_IMMUTABLE, "zone on opponent")
	_expect(errors, world.tile_at(56, 56).zone == SliceConstants.Zone.NONE, "opponent zone unchanged")

	var zone_ok := world.apply(faction_a, GameCommand.set_zone(0, 0, SliceConstants.Zone.R))
	_expect(errors, zone_ok["reason"] == ReasonCode.Id.OK and world.tile_at(0, 0).zone == SliceConstants.Zone.R, "zone own")
	_expect(errors, world.tile_at(0, 0).has_building, "zone sets building")
	_expect(errors, _has_kind(zone_ok["events"], ServerEvent.Kind.POWER_ALERT), "residential power alert")

	var demolish_enemy := world.apply(faction_a, GameCommand.demolish_own(56, 56))
	_expect(errors, demolish_enemy["reason"] == ReasonCode.Id.OPPONENT_IMMUTABLE, "demolish opponent")

	world.apply(faction_a, GameCommand.set_zone(1, 0, SliceConstants.Zone.C))
	var demolish := world.apply(faction_a, GameCommand.demolish_own(1, 0))
	_expect(errors, demolish["reason"] == ReasonCode.Id.OK and not world.tile_at(1, 0).has_building, "demolish own")
	_expect(errors, world.tile_at(1, 0).zone == SliceConstants.Zone.C, "demolish keeps zone")

	var edge_neutral := world.apply(faction_a, GameCommand.add_edge(Vector2i(0, 7), Vector2i(0, 8)))
	_expect(errors, edge_neutral["reason"] == ReasonCode.Id.EDGE_RULE and world.find_edge(Vector2i(0, 7), Vector2i(0, 8)) == null, "edge to neutral")

	var edge_enemy := world.apply(faction_a, GameCommand.add_edge(Vector2i(56, 56), Vector2i(57, 56)))
	_expect(errors, edge_enemy["reason"] == ReasonCode.Id.OPPONENT_IMMUTABLE, "edge on opponent")

	var diagonal := world.apply(faction_a, GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 1)))
	_expect(errors, diagonal["reason"] == ReasonCode.Id.NOT_ORTHOGONAL, "diagonal edge")

	var edge_ok := world.apply(faction_a, GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 0)))
	_expect(errors, edge_ok["reason"] == ReasonCode.Id.OK and edge_ok["events"][0].kind == ServerEvent.Kind.EDGE_DELTA, "legal edge")
	_expect(errors, world.find_edge(Vector2i(1, 0), Vector2i(0, 0)) != null and not edge_ok["events"][0].edge_delta.removed, "edge stored")

	var removed := world.apply(faction_a, GameCommand.remove_edge(Vector2i(1, 0), Vector2i(0, 0)))
	_expect(errors, removed["reason"] == ReasonCode.Id.OK and removed["events"][0].edge_delta.removed, "remove edge")
	_expect(errors, world.find_edge(Vector2i(0, 0), Vector2i(1, 0)) == null, "edge gone")
	var missing := world.apply(faction_a, GameCommand.remove_edge(Vector2i(0, 0), Vector2i(1, 0)))
	_expect(errors, missing["reason"] == ReasonCode.Id.EDGE_RULE, "remove missing edge")

	var power_enemy := world.apply(faction_a, GameCommand.place_power(56, 56))
	_expect(errors, power_enemy["reason"] == ReasonCode.Id.OPPONENT_IMMUTABLE and not world.has_power_source(56, 56), "power on opponent")


func _check_power_tick_interest(errors: Array[String]) -> void:
	var world = WorldStateScript.new()
	var faction_a := SliceConstants.Owner.FACTION_A
	var placed := world.apply(faction_a, GameCommand.place_power(0, 0))
	_expect(errors, placed["reason"] == ReasonCode.Id.OK and world.has_power_source(0, 0), "place power")
	_expect(errors, world.tile_at(0, 4).power_covered and world.tile_at(4, 0).power_covered, "radius covered")
	_expect(errors, not world.tile_at(0, 5).power_covered and not world.tile_at(5, 0).power_covered, "outside radius")
	world.apply(faction_a, GameCommand.remove_power(0, 0))
	_expect(errors, not world.has_power_source(0, 0) and not world.tile_at(0, 4).power_covered, "remove power")

	world.apply(faction_a, GameCommand.set_zone(0, 0, SliceConstants.Zone.R))
	world.apply(faction_a, GameCommand.set_zone(1, 0, SliceConstants.Zone.C))
	world.apply(faction_a, GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 0)))
	var ticked: Array = world.sim_tick(1)
	var congestion: ServerEvent = _first_kind(ticked, ServerEvent.Kind.CONGESTION_ALERT)
	_expect(errors, congestion != null and is_equal_approx(congestion.congestion_alert.congestion, WorldStateScript.CONGESTION_WHEN_ZONED), "tick congestion")
	_expect(errors, _first_kind(ticked, ServerEvent.Kind.SCORE_TICK) != null, "tick score")
	var crisis_events: Array = world.sim_tick(WorldStateScript.CRISIS_TICK)
	var crisis: ServerEvent = _first_kind(crisis_events, ServerEvent.Kind.CRISIS_EVENT)
	_expect(errors, crisis != null and crisis.crisis_event.active and world.crisis_active, "shared crisis")

	var keys := {}
	for block in world.interest_for(faction_a, null):
		keys[block.key()] = true
	_expect(errors, keys.has("0,0") and keys.has("1,0") and keys.has("0,1"), "own and border interest")
	_expect(errors, not keys.has("7,7"), "far faction not subscribed")
	var with_camera := {}
	for block in world.interest_for(faction_a, InterestId.new(3, 3)):
		with_camera[block.key()] = true
	_expect(errors, with_camera.has("3,3") and with_camera.has("0,0"), "camera block")


func _check_client_interest_cache(errors: Array[String]) -> void:
	# load() at runtime, after the GameNet autoload exists. A parse-time
	# ClientSession reference compiles session.gd before that autoload.
	var session = load("res://client/session.gd").new()
	var far := TileDelta.from_cell(40, 40)
	far.owner = SliceConstants.Owner.FACTION_B
	session._apply(ServerEvent.with_tile_delta(far))
	_expect(errors, session.tile(40, 40) == null, "delta outside subscription is not cached")

	var update := InterestUpdate.new()
	update.add = [
		InterestId.from_tile(1, 1),
		InterestId.from_tile(8, 0),
		InterestId.from_tile(40, 40),
	]
	session._apply(ServerEvent.with_interest_update(update))
	var near := TileDelta.from_cell(1, 1)
	near.owner = SliceConstants.Owner.FACTION_A
	var span := EdgeDelta.new()
	span.a = Vector2i(7, 0)
	span.b = Vector2i(8, 0)
	var far_edge := EdgeDelta.new()
	far_edge.a = Vector2i(40, 40)
	far_edge.b = Vector2i(41, 40)
	session._apply(ServerEvent.with_tile_delta(near))
	session._apply(ServerEvent.with_tile_delta(far))
	session._apply(ServerEvent.with_edge_delta(span))
	session._apply(ServerEvent.with_edge_delta(far_edge))
	_expect(errors, session.tile(1, 1) != null and session.tile(40, 40) != null, "subscribed tiles cached")
	_expect(errors, session.edge(span.a, span.b) != null and session.edge(far_edge.a, far_edge.b) != null, "subscribed edges cached")

	var leave_far := InterestUpdate.new()
	leave_far.remove = [InterestId.from_tile(40, 40)]
	session._apply(ServerEvent.with_interest_update(leave_far))
	_expect(errors, session.tile(1, 1) != null, "tile in a block that stayed")
	_expect(errors, session.tile(40, 40) == null, "tile left with its block")
	_expect(errors, session.edge(far_edge.a, far_edge.b) == null, "edge left with its block")
	_expect(errors, session.edge(span.a, span.b) != null, "edge kept while one end stays subscribed")

	var leave_span := InterestUpdate.new()
	leave_span.remove = [InterestId.from_tile(1, 1), InterestId.from_tile(8, 0)]
	session._apply(ServerEvent.with_interest_update(leave_span))
	_expect(errors, session.tile(1, 1) == null and session.edge(span.a, span.b) == null, "cache empty after last blocks leave")
	session.free()


func _has_kind(events: Array, kind: int) -> bool:
	return _first_kind(events, kind) != null


func _first_kind(events: Array, kind: int) -> ServerEvent:
	for event in events:
		if event.kind == kind:
			return event
	return null


func _expect(errors: Array[String], cond: bool, message: String) -> void:
	if not cond:
		errors.append(message)

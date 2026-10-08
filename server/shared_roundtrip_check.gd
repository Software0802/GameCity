extends SceneTree

## Headless contract check for every payload in shared/. No second peer.
##   godot --headless --path . -s res://server/shared_roundtrip_check.gd
## Each payload is built with non-default values, sent through
## to_dict → JSON.stringify → JSON.parse_string → from_dict, and its to_dict()
## compared field by field with strict types. Enum ints that other workers depend
## on are pinned here. Prints SHARED_OK and exits 0, or each failure and exits 1.

const MAX_PRINTED := 40


func _initialize() -> void:
	var errors: Array[String] = []
	_check_constants(errors)
	_check_commands(errors)
	_check_reason_codes(errors)
	_check_command_reject(errors)
	_check_tile_delta(errors)
	_check_edge_delta(errors)
	_check_interest(errors)
	_check_interest_update(errors)
	_check_match_start(errors)
	_check_match_end(errors)
	_check_score_tick(errors)
	_check_power_alert(errors)
	_check_congestion_alert(errors)
	_check_crisis_event(errors)
	_check_region_summary(errors)
	_check_client_hello(errors)
	_check_server_welcome(errors)
	_check_faction_state(errors)
	_check_server_event(errors)
	if errors.is_empty():
		print("SHARED_OK")
		quit(0)
	else:
		var shown := 0
		for err in errors:
			if shown >= MAX_PRINTED:
				print("SHARED_FAIL ... %d more" % (errors.size() - shown))
				break
			print("SHARED_FAIL %s" % err)
			shown += 1
		quit(1)


func _check_constants(errors: Array[String]) -> void:
	_expect(errors, SliceConstants.MAP_SIZE == 128, "MAP_SIZE 128")
	_expect(errors, SliceConstants.INTEREST_BLOCK == 8, "INTEREST_BLOCK 8")
	_expect(errors, SliceConstants.BLOCKS_PER_AXIS == 16, "BLOCKS_PER_AXIS derived 16")
	_expect(errors, SliceConstants.tile_id(1, 1) == 129, "tile_id uses MAP_SIZE")
	_expect(errors, SliceConstants.tile_id(127, 127) == 128 * 128 - 1, "tile_id last cell")
	_expect(errors, SliceConstants.in_map(127, 127) and not SliceConstants.in_map(128, 0) and not SliceConstants.in_map(0, 128), "in_map bounds")
	_expect(errors, not SliceConstants.in_map(-1, 0) and not SliceConstants.in_map(0, -1), "in_map negative")
	_expect(errors, is_equal_approx(SliceConstants.SIM_TICK_SEC, 1.0), "SIM_TICK_SEC")
	_expect(errors, SliceConstants.ROUND_SECONDS_DEFAULT == 604800 and SliceConstants.ROUND_SECONDS_TEST == 3600, "round seconds")
	_expect(errors, is_equal_approx(SliceConstants.PACE_DEFAULT, 1.0), "PACE_DEFAULT")
	_expect(errors, SliceConstants.SAVE_FORMAT_VERSION == 1 and SliceConstants.PROTOCOL_VERSION == 1, "format versions")
	_expect(errors, SliceConstants.FIELD_QUANT == 8, "FIELD_QUANT")
	_expect(errors, SliceConstants.START_TREASURY == 5000 and SliceConstants.COST_CLAIM_BASE == 50, "treasury and claim cost")
	_expect(errors, is_equal_approx(SliceConstants.COST_CLAIM_GROWTH, 0.01), "COST_CLAIM_GROWTH")
	_expect(errors, SliceConstants.COST_EDGE == 20 and SliceConstants.COST_POWER == 400, "edge and power cost")
	_expect(errors, is_equal_approx(SliceConstants.UPKEEP_POWER_PER_SEC, 0.5), "UPKEEP_POWER_PER_SEC")
	_expect(errors, is_equal_approx(SliceConstants.TAX_RATE_DEFAULT, 0.10), "TAX_RATE_DEFAULT")
	_expect(errors, is_equal_approx(SliceConstants.TAX_RATE_MIN, 0.0) and is_equal_approx(SliceConstants.TAX_RATE_MAX, 0.30), "tax rate range")
	_expect(errors, is_equal_approx(SliceConstants.INCOME_PER_POP_PER_SEC, 0.02) and is_equal_approx(SliceConstants.INCOME_PER_JOB_PER_SEC, 0.01), "income rates")
	_expect(errors, SliceConstants.POWER_RADIUS == 4 and SliceConstants.POWER_PLANT_CAPACITY == 60, "power radius and capacity")
	_expect(errors, SliceConstants.TIER_UP_SECONDS == 120 and SliceConstants.TIER_DOWN_SECONDS == 180, "tier seconds")
	_expect(errors, is_equal_approx(SliceConstants.SAT_UP, 0.7) and is_equal_approx(SliceConstants.SAT_DOWN, 0.3), "satisfaction thresholds")
	_expect(errors, SliceConstants.TIER_POP == [1, 3, 8] and SliceConstants.TIER_JOBS == [2, 6, 16], "tier tables")
	_expect(errors, SliceConstants.TIER_POP.size() == SliceConstants.BUILDING_TIER_MAX + 1, "tier table covers every tier")
	_expect(errors, SliceConstants.POLLUTION_RADIUS == 3 and SliceConstants.CONGESTION_CAPACITY == 10, "pollution and congestion")
	_expect(errors, is_equal_approx(SliceConstants.CRISIS_AT_FRACTION, 0.5) and SliceConstants.CRISIS_DURATION_SEC == 90 and is_equal_approx(SliceConstants.CRISIS_CAPACITY_FACTOR, 0.5), "crisis constants")
	_expect(errors, SliceConstants.Owner.NEUTRAL == -1 and SliceConstants.Owner.FACTION_A == 0 and SliceConstants.Owner.FACTION_B == 1, "Owner ints")
	_expect(errors, SliceConstants.Zone.NONE == 0 and SliceConstants.Zone.R == 1 and SliceConstants.Zone.C == 2 and SliceConstants.Zone.I == 3, "Zone ints")
	_expect(errors, SliceConstants.is_zone(SliceConstants.Zone.I) and not SliceConstants.is_zone(4), "is_zone")


func _check_commands(errors: Array[String]) -> void:
	_expect(errors, GameCommand.Kind.DEMOLISH_OWN == 6 and GameCommand.Kind.SET_TAX_RATE == 7, "Kind ints stable, SET_TAX_RATE appended")
	var size := SliceConstants.MAP_SIZE
	var claim := GameCommand.claim_tile(size - 1, size - 1)
	_expect(errors, claim.validate_shape() == ReasonCode.Id.OK, "claim last cell in map")
	_expect(errors, GameCommand.claim_tile(size, 0).validate_shape() == ReasonCode.Id.OUT_OF_BOUNDS, "claim MAP_SIZE out of bounds")
	_expect(errors, GameCommand.claim_tile(63, 64).validate_shape() == ReasonCode.Id.OK, "old 64 edge is inside now")
	_expect(errors, GameCommand.set_zone(0, 0, 99).validate_shape() == ReasonCode.Id.INVALID_ZONE, "invalid zone")
	_expect(errors, GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 1)).validate_shape() == ReasonCode.Id.NOT_ORTHOGONAL, "diagonal edge")
	_expect(errors, GameCommand.add_edge(Vector2i(size - 1, 0), Vector2i(size, 0)).validate_shape() == ReasonCode.Id.OUT_OF_BOUNDS, "edge off map")
	_expect(errors, GameCommand.remove_edge(Vector2i(5, 5), Vector2i(5, 6)).validate_shape() == ReasonCode.Id.OK, "remove edge ok")

	var tax := GameCommand.set_tax_rate(0.2)
	_expect(errors, tax.kind == GameCommand.Kind.SET_TAX_RATE and is_equal_approx(tax.rate, 0.2), "set_tax_rate factory")
	_expect(errors, tax.validate_shape() == ReasonCode.Id.OK, "tax 0.2 ok")
	_expect(errors, tax.tile_x == -1 and tax.tile_y == -1 and tax.zone == SliceConstants.Zone.NONE, "tax command leaves tile fields unused")
	_expect(errors, GameCommand.set_tax_rate(SliceConstants.TAX_RATE_MIN).validate_shape() == ReasonCode.Id.OK, "tax at min ok")
	_expect(errors, GameCommand.set_tax_rate(SliceConstants.TAX_RATE_MAX).validate_shape() == ReasonCode.Id.OK, "tax at max ok")
	_expect(errors, GameCommand.set_tax_rate(SliceConstants.TAX_RATE_MAX + 0.01).validate_shape() == ReasonCode.Id.INVALID_RATE, "tax above max")
	_expect(errors, GameCommand.set_tax_rate(SliceConstants.TAX_RATE_MIN - 0.01).validate_shape() == ReasonCode.Id.INVALID_RATE, "tax below min")
	_expect(errors, GameCommand.set_tax_rate(NAN).validate_shape() == ReasonCode.Id.INVALID_RATE, "tax NaN")
	_expect(errors, GameCommand.set_tax_rate(INF).validate_shape() == ReasonCode.Id.INVALID_RATE, "tax INF")
	var claim_odd_rate := GameCommand.claim_tile(3, 4)
	claim_odd_rate.rate = 9.0
	_expect(errors, claim_odd_rate.validate_shape() == ReasonCode.Id.OK, "rate ignored by tile commands")
	var unknown := GameCommand.new()
	unknown.kind = 99
	_expect(errors, unknown.validate_shape() == ReasonCode.Id.UNKNOWN_COMMAND, "unknown kind")

	var samples: Array[GameCommand] = [
		GameCommand.claim_tile(3, 4),
		GameCommand.set_zone(5, 6, SliceConstants.Zone.I),
		GameCommand.add_edge(Vector2i(1, 2), Vector2i(1, 3)),
		GameCommand.remove_edge(Vector2i(120, 127), Vector2i(121, 127)),
		GameCommand.place_power(7, 8),
		GameCommand.remove_power(9, 10),
		GameCommand.demolish_own(11, 12),
		GameCommand.set_tax_rate(0.25),
	]
	for cmd in samples:
		var back := GameCommand.from_dict(_json(cmd.to_dict()))
		_same(errors, cmd.to_dict(), back.to_dict(), "GameCommand kind %d" % cmd.kind)
		_expect(errors, back.kind == cmd.kind and back.edge_a == cmd.edge_a and back.edge_b == cmd.edge_b, "GameCommand kind %d fields" % cmd.kind)
	_expect(errors, cmd_dict_keys(samples[0].to_dict()), "GameCommand dict keys")
	var legacy := GameCommand.from_dict({"kind": GameCommand.Kind.CLAIM_TILE, "tile_x": 1, "tile_y": 2})
	_expect(errors, is_equal_approx(legacy.rate, SliceConstants.TAX_RATE_DEFAULT), "missing rate defaults to TAX_RATE_DEFAULT")


static func cmd_dict_keys(d: Dictionary) -> bool:
	for key in ["kind", "tile_x", "tile_y", "zone", "edge_a", "edge_b", "rate"]:
		if not d.has(key):
			return false
	return d.size() == 7


func _check_reason_codes(errors: Array[String]) -> void:
	_expect(errors, ReasonCode.Id.OK == 0 and ReasonCode.Id.EDGE_RULE == 11, "existing reason ints stable")
	_expect(errors, ReasonCode.Id.INSUFFICIENT_FUNDS == 12, "INSUFFICIENT_FUNDS appended")
	_expect(errors, ReasonCode.Id.INVALID_RATE == 13, "INVALID_RATE appended")
	_expect(errors, ReasonCode.Id.NOT_AUTHENTICATED == 14, "NOT_AUTHENTICATED appended")


func _check_command_reject(errors: Array[String]) -> void:
	var reject := CommandReject.new(GameCommand.set_tax_rate(0.5), ReasonCode.Id.INVALID_RATE, "rate")
	var back := CommandReject.from_dict(_json(reject.to_dict()))
	_same(errors, reject.to_dict(), back.to_dict(), "CommandReject")
	_expect(errors, back.kind == GameCommand.Kind.SET_TAX_RATE and back.reason == ReasonCode.Id.INVALID_RATE and is_equal_approx(back.command.rate, 0.5), "CommandReject fields")
	var bare := CommandReject.new(null, ReasonCode.Id.NOT_AUTHENTICATED, "hello first")
	var bare_back := CommandReject.from_dict(_json(bare.to_dict()))
	_expect(errors, bare_back.command == null and bare_back.kind == -1 and bare_back.reason == ReasonCode.Id.NOT_AUTHENTICATED, "CommandReject without command")


func _check_tile_delta(errors: Array[String]) -> void:
	var tile := TileDelta.from_cell(127, 3)
	_expect(errors, tile.id == SliceConstants.tile_id(127, 3), "from_cell id")
	tile.owner = SliceConstants.Owner.FACTION_B
	tile.zone = SliceConstants.Zone.I
	tile.has_building = true
	tile.building_tier = 2
	tile.power_covered = true
	tile.satisfaction = 0.875
	tile.pollution = 0.375
	tile.brownout = true
	var back := TileDelta.from_dict(_json(tile.to_dict()))
	_same(errors, tile.to_dict(), back.to_dict(), "TileDelta")
	_expect(errors, back.brownout and is_equal_approx(back.satisfaction, 0.875) and is_equal_approx(back.pollution, 0.375), "TileDelta new fields")
	var keys := tile.to_dict().keys()
	for key in ["id", "x", "y", "owner", "zone", "has_building", "building_tier", "power_covered", "satisfaction", "pollution", "brownout"]:
		_expect(errors, keys.has(key), "TileDelta key %s" % key)
	var legacy := TileDelta.from_dict({"x": 4, "y": 5, "owner": 0})
	_expect(errors, legacy.id == SliceConstants.tile_id(4, 5) and not legacy.brownout and is_zero_approx(legacy.satisfaction) and is_zero_approx(legacy.pollution), "TileDelta legacy dict defaults")


func _check_edge_delta(errors: Array[String]) -> void:
	_expect(errors, EdgeDelta.is_orthogonal(Vector2i(0, 0), Vector2i(1, 0)) and EdgeDelta.is_orthogonal(Vector2i(5, 5), Vector2i(5, 4)), "orthogonal neighbors")
	_expect(errors, not EdgeDelta.is_orthogonal(Vector2i(0, 0), Vector2i(1, 1)) and not EdgeDelta.is_orthogonal(Vector2i(0, 0), Vector2i(0, 0)) and not EdgeDelta.is_orthogonal(Vector2i(0, 0), Vector2i(2, 0)), "not orthogonal")
	var edge := EdgeDelta.new()
	edge.a = Vector2i(120, 121)
	edge.b = Vector2i(121, 121)
	edge.capacity = 10
	edge.congestion = 0.35
	var back := EdgeDelta.from_dict(_json(edge.to_dict()))
	_same(errors, edge.to_dict(), back.to_dict(), "EdgeDelta")
	var removed := EdgeDelta.make_removed(Vector2i(1, 1), Vector2i(1, 2))
	var removed_back := EdgeDelta.from_dict(_json(removed.to_dict()))
	_expect(errors, removed_back.removed and removed_back.a == Vector2i(1, 1) and removed_back.b == Vector2i(1, 2), "EdgeDelta removed")
	_expect(errors, EdgeDelta.point_from_dict(Vector2i(3, 4)) == Vector2i(3, 4), "point_from_dict accepts Vector2i")
	_expect(errors, EdgeDelta.point_from_dict(null) == Vector2i(-1, -1), "point_from_dict rejects garbage")


func _check_interest(errors: Array[String]) -> void:
	var last := InterestId.from_tile(127, 127)
	_expect(errors, last.block_x == 15 and last.block_y == 15 and last.linear_id() == 255 and last.key() == "15,15", "last block")
	var mid := InterestId.from_tile(8, 0)
	_expect(errors, mid.block_x == 1 and mid.block_y == 0 and mid.linear_id() == 1, "block 1,0")
	var from_linear := InterestId.from_linear(17)
	_expect(errors, from_linear.block_x == 1 and from_linear.block_y == 1, "from_linear 17 at 16 per axis")
	_expect(errors, InterestId.from_key("3,9").linear_id() == 9 * 16 + 3, "from_key")
	var back := InterestId.from_dict(_json(last.to_dict()))
	_same(errors, last.to_dict(), back.to_dict(), "InterestId")
	_expect(errors, InterestId.from_dict({"linear_id": 33}).key() == "1,2", "from_dict linear fallback")
	_expect(errors, InterestId.from_dict({"key": "2,3"}).linear_id() == 3 * 16 + 2, "from_dict key fallback")
	_expect(errors, InterestId.from_any(34).key() == "2,2" and InterestId.from_any(34.0).key() == "2,2", "from_any int and float")
	_expect(errors, InterestId.from_any("4,5").linear_id() == 5 * 16 + 4, "from_any string")
	_expect(errors, InterestId.from_any(last).key() == "15,15", "from_any passthrough")


func _check_interest_update(errors: Array[String]) -> void:
	var update := InterestUpdate.new()
	update.add = [InterestId.new(1, 2), InterestId.new(15, 15)]
	update.remove = [InterestId.new(0, 0)]
	var back := InterestUpdate.from_dict(_json(update.to_dict()))
	_same(errors, update.to_dict(), back.to_dict(), "InterestUpdate")
	var mixed := InterestUpdate.from_dict({"add": [17, "3,3", {"block_x": 4, "block_y": 4}], "remove": []})
	_expect(errors, mixed.add.size() == 3 and mixed.add[0].key() == "1,1" and mixed.add[1].key() == "3,3" and mixed.add[2].key() == "4,4", "InterestUpdate mixed wire forms")


func _check_match_start(errors: Array[String]) -> void:
	var fresh := MatchStart.new()
	_expect(errors, fresh.map_size == 128 and fresh.interest_block == 8 and fresh.faction_count == 2, "MatchStart defaults echo constants")
	_expect(errors, fresh.round_seconds == SliceConstants.ROUND_SECONDS_DEFAULT and is_equal_approx(fresh.pace, SliceConstants.PACE_DEFAULT), "MatchStart clock defaults")
	var start := MatchStart.new()
	start.round_seconds = 3600
	start.round_ends_at_unix = 1790000000
	start.server_unix = 1789996400
	start.pace = 0.01
	var back := MatchStart.from_dict(_json(start.to_dict()))
	_same(errors, start.to_dict(), back.to_dict(), "MatchStart")
	_expect(errors, back.round_ends_at_unix == 1790000000 and back.server_unix == 1789996400 and is_equal_approx(back.pace, 0.01), "MatchStart new fields")
	for key in ["map_size", "interest_block", "faction_count", "round_seconds", "round_ends_at_unix", "server_unix", "pace"]:
		_expect(errors, start.to_dict().has(key), "MatchStart key %s" % key)


func _check_match_end(errors: Array[String]) -> void:
	_expect(errors, MatchEnd.REASON_CLOCK == "clock", "REASON_CLOCK literal")
	_expect(errors, MatchEnd.REASON_SERVER_STOP == "server_stop", "REASON_SERVER_STOP literal")
	var end := MatchEnd.new()
	end.winner = SliceConstants.Owner.FACTION_B
	end.reason = MatchEnd.REASON_CLOCK
	end.final_scores = _sample_score()
	var back := MatchEnd.from_dict(_json(end.to_dict()))
	_same(errors, end.to_dict(), back.to_dict(), "MatchEnd with scores")
	_expect(errors, back.final_scores != null and back.final_scores.seconds_remaining == 0 and back.final_scores.factions.size() == 2, "MatchEnd final_scores restored")
	var stop := MatchEnd.new()
	stop.reason = MatchEnd.REASON_SERVER_STOP
	var stop_dict := stop.to_dict()
	_expect(errors, stop_dict.has("final_scores") and stop_dict["final_scores"] is Dictionary and stop_dict["final_scores"].is_empty(), "MatchEnd null scores written as {}")
	var stop_back := MatchEnd.from_dict(_json(stop_dict))
	_expect(errors, stop_back.final_scores == null and stop_back.winner == SliceConstants.Owner.NEUTRAL and stop_back.reason == "server_stop", "MatchEnd null scores read back as null")


func _sample_score() -> ScoreTick:
	var tick := ScoreTick.new()
	tick.tick_index = 42
	tick.seconds_remaining = 0
	var a := ScoreTick.FactionScore.new()
	a.faction = SliceConstants.Owner.FACTION_A
	a.pop_raw = 3.0
	a.fiscal_raw = -2.0
	a.control_raw = 70.0
	var b := ScoreTick.FactionScore.new()
	b.faction = SliceConstants.Owner.FACTION_B
	b.pop_raw = 1.0
	b.fiscal_raw = 5.0
	b.control_raw = 70.0
	a.pop = ScoreTick.share(a.pop_raw, b.pop_raw)
	a.fiscal = ScoreTick.share(a.fiscal_raw, b.fiscal_raw)
	a.control = ScoreTick.share(a.control_raw, b.control_raw)
	b.pop = ScoreTick.share(b.pop_raw, a.pop_raw)
	b.fiscal = ScoreTick.share(b.fiscal_raw, a.fiscal_raw)
	b.control = ScoreTick.share(b.control_raw, a.control_raw)
	tick.factions = [a, b]
	return tick


func _check_score_tick(errors: Array[String]) -> void:
	_expect(errors, is_equal_approx(ScoreTick.share(0.0, 0.0), 0.5), "share both zero is 0.5")
	_expect(errors, is_equal_approx(ScoreTick.share(3.0, 1.0), 0.75), "share 3:1")
	_expect(errors, is_equal_approx(ScoreTick.share(-5.0, 0.0), 0.5), "share negative clamps to 0 then 0.5")
	_expect(errors, is_equal_approx(ScoreTick.share(-5.0, 2.0), 0.0), "share negative vs positive is 0")
	_expect(errors, is_equal_approx(ScoreTick.share(2.0, -5.0), 1.0), "share positive vs negative is 1")
	_expect(errors, is_equal_approx(ScoreTick.share(1.0, 3.0) + ScoreTick.share(3.0, 1.0), 1.0), "shares sum to 1")
	var tick := _sample_score()
	tick.seconds_remaining = 12345
	var back := ScoreTick.from_dict(_json(tick.to_dict()))
	_same(errors, tick.to_dict(), back.to_dict(), "ScoreTick")
	_expect(errors, back.seconds_remaining == 12345 and back.tick_index == 42, "ScoreTick top-level fields")
	var line := back.factions[0]
	_expect(errors, is_equal_approx(line.pop, 0.75) and is_equal_approx(line.fiscal, 0.0) and is_equal_approx(line.control, 0.5), "FactionScore normalized values")
	_expect(errors, is_equal_approx(line.pop_raw, 3.0) and is_equal_approx(line.fiscal_raw, -2.0) and is_equal_approx(line.control_raw, 70.0), "FactionScore raw values")
	var expected_total := 0.75 * SliceConstants.SCORE_WEIGHT_POP + 0.0 * SliceConstants.SCORE_WEIGHT_FISCAL + 0.5 * SliceConstants.SCORE_WEIGHT_CONTROL
	_expect(errors, is_equal_approx(line.total(), expected_total) and line.total() >= 0.0 and line.total() <= 1.0, "FactionScore total in 0–1")
	var line_dict := line.to_dict()
	for key in ["faction", "pop", "fiscal", "control", "pop_raw", "fiscal_raw", "control_raw", "total"]:
		_expect(errors, line_dict.has(key), "FactionScore key %s" % key)
	_expect(errors, tick.to_dict().has("seconds_remaining") and tick.to_dict().has("factions") and tick.to_dict().has("tick_index"), "ScoreTick keys")


func _check_power_alert(errors: Array[String]) -> void:
	var alert := PowerAlert.new()
	alert.x = 100
	alert.y = 101
	alert.power_covered = true
	alert.shortage = false
	alert.brownout = true
	var back := PowerAlert.from_dict(_json(alert.to_dict()))
	_same(errors, alert.to_dict(), back.to_dict(), "PowerAlert")
	_expect(errors, back.brownout and back.power_covered and not back.shortage, "PowerAlert brownout")


func _check_congestion_alert(errors: Array[String]) -> void:
	var alert := CongestionAlert.new()
	alert.a = Vector2i(10, 11)
	alert.b = Vector2i(10, 12)
	alert.congestion = 0.75
	var back := CongestionAlert.from_dict(_json(alert.to_dict()))
	_same(errors, alert.to_dict(), back.to_dict(), "CongestionAlert")


func _check_crisis_event(errors: Array[String]) -> void:
	_expect(errors, CrisisEvent.KIND_GRID_STORM == "grid_storm", "KIND_GRID_STORM literal")
	var crisis := CrisisEvent.new()
	crisis.crisis_id = "round1"
	crisis.kind = CrisisEvent.KIND_GRID_STORM
	crisis.active = true
	crisis.detail = "shared"
	crisis.ends_at_unix = 1790000090
	var back := CrisisEvent.from_dict(_json(crisis.to_dict()))
	_same(errors, crisis.to_dict(), back.to_dict(), "CrisisEvent")
	_expect(errors, back.kind == "grid_storm" and back.ends_at_unix == 1790000090, "CrisisEvent new fields")
	var legacy := CrisisEvent.from_dict({"crisis_id": "x", "active": true})
	_expect(errors, legacy.kind == "" and legacy.ends_at_unix == 0, "CrisisEvent legacy defaults")


func _check_region_summary(errors: Array[String]) -> void:
	var summary := RegionSummary.new()
	summary.interest = InterestId.new(15, 14)
	summary.population = 9
	summary.power_alert = true
	summary.crisis = true
	summary.pollution_avg = 0.25
	summary.brownout = true
	var back := RegionSummary.from_dict(_json(summary.to_dict()))
	_same(errors, summary.to_dict(), back.to_dict(), "RegionSummary")
	_expect(errors, back.interest != null and back.interest.key() == "15,14" and is_equal_approx(back.pollution_avg, 0.25) and back.brownout, "RegionSummary fields")
	_expect(errors, RegionSummary.from_dict({"interest": 17}).interest.key() == "1,1", "RegionSummary interest as linear id")
	_expect(errors, RegionSummary.from_dict({"interest": "2,2"}).interest.key() == "2,2", "RegionSummary interest as key")
	_expect(errors, RegionSummary.from_dict({}).interest == null, "RegionSummary without interest")


func _check_client_hello(errors: Array[String]) -> void:
	var fresh := ClientHello.new()
	_expect(errors, fresh.token == "" and fresh.name == "" and fresh.protocol == SliceConstants.PROTOCOL_VERSION, "ClientHello defaults")
	_expect(errors, not ClientHello.is_valid_name(""), "empty name invalid")
	_expect(errors, ClientHello.is_valid_name("a"), "1-char name valid")
	_expect(errors, ClientHello.is_valid_name("abcdefghijklmnopqrstuvwx"), "24-char name valid")
	_expect(errors, not ClientHello.is_valid_name("abcdefghijklmnopqrstuvwxy"), "25-char name invalid")
	_expect(errors, ClientHello.is_valid_name("志坤的城市"), "unicode name counts code points")
	var hello := ClientHello.new()
	hello.token = "tok-123"
	hello.name = "player one"
	hello.protocol = 1
	var back := ClientHello.from_dict(_json(hello.to_dict()))
	_same(errors, hello.to_dict(), back.to_dict(), "ClientHello")
	_expect(errors, back.token == "tok-123" and back.name == "player one" and back.protocol == 1, "ClientHello fields")
	for key in ["token", "name", "protocol"]:
		_expect(errors, hello.to_dict().has(key), "ClientHello key %s" % key)


func _check_server_welcome(errors: Array[String]) -> void:
	var welcome := ServerWelcome.new()
	welcome.token = "tok-456"
	welcome.player_id = 7
	welcome.faction = SliceConstants.Owner.FACTION_B
	welcome.name = "player two"
	welcome.returning = true
	var back := ServerWelcome.from_dict(_json(welcome.to_dict()))
	_same(errors, welcome.to_dict(), back.to_dict(), "ServerWelcome")
	_expect(errors, back.player_id == 7 and back.faction == SliceConstants.Owner.FACTION_B and back.returning, "ServerWelcome fields")
	for key in ["token", "player_id", "faction", "name", "returning"]:
		_expect(errors, welcome.to_dict().has(key), "ServerWelcome key %s" % key)
	var fresh := ServerWelcome.new()
	_expect(errors, fresh.player_id == -1 and fresh.faction == SliceConstants.Owner.NEUTRAL and not fresh.returning, "ServerWelcome defaults")


func _check_faction_state(errors: Array[String]) -> void:
	var state := FactionState.new()
	state.faction = SliceConstants.Owner.FACTION_B
	state.treasury = 4321.5
	state.income_per_sec = -0.75
	state.population = 120
	state.jobs = 80
	state.technicians = 0
	state.tax_rate = 0.15
	state.demand_r = 0.5
	state.demand_c = -0.25
	state.demand_i = 1.0
	state.power_capacity = 40
	state.power_load = 44
	var back := FactionState.from_dict(_json(state.to_dict()))
	_same(errors, state.to_dict(), back.to_dict(), "FactionState")
	_expect(errors, back.population == 120 and back.jobs == 80 and back.power_load == 44 and is_equal_approx(back.demand_c, -0.25), "FactionState fields")
	var keys := state.to_dict()
	for key in ["faction", "treasury", "income_per_sec", "population", "jobs", "technicians", "tax_rate", "demand_r", "demand_c", "demand_i", "power_capacity", "power_load"]:
		_expect(errors, keys.has(key), "FactionState key %s" % key)
	_expect(errors, keys.size() == 12, "FactionState has exactly 12 keys")


func _check_server_event(errors: Array[String]) -> void:
	_expect(errors, ServerEvent.Kind.REGION_SUMMARY == 10, "existing ServerEvent ints stable")
	_expect(errors, ServerEvent.Kind.WELCOME == 11 and ServerEvent.Kind.FACTION_STATE == 12, "WELCOME and FACTION_STATE appended")

	var welcome := ServerWelcome.new()
	welcome.token = "t"
	welcome.player_id = 3
	var state := FactionState.new()
	state.treasury = 99.0
	var tile := TileDelta.from_cell(2, 5)
	tile.brownout = true
	var edge := EdgeDelta.make_removed(Vector2i(0, 0), Vector2i(1, 0))
	var power := PowerAlert.new()
	power.brownout = true
	var congestion := CongestionAlert.new()
	congestion.congestion = 0.5
	var crisis := CrisisEvent.new()
	crisis.kind = CrisisEvent.KIND_GRID_STORM
	var end := MatchEnd.new()
	end.reason = MatchEnd.REASON_CLOCK
	end.final_scores = _sample_score()
	var reject := CommandReject.new(GameCommand.set_tax_rate(2.0), ReasonCode.Id.INVALID_RATE, "")
	var update := InterestUpdate.new()
	update.add = [InterestId.new(1, 1)]
	var summary := RegionSummary.new()
	summary.interest = InterestId.new(2, 2)
	summary.brownout = true

	var cases: Array = [
		[ServerEvent.with_match_start(MatchStart.new()), ServerEvent.Kind.MATCH_START, "match_start"],
		[ServerEvent.with_tile_delta(tile), ServerEvent.Kind.TILE_DELTA, "tile_delta"],
		[ServerEvent.with_edge_delta(edge), ServerEvent.Kind.EDGE_DELTA, "edge_delta"],
		[ServerEvent.with_power_alert(power), ServerEvent.Kind.POWER_ALERT, "power_alert"],
		[ServerEvent.with_congestion_alert(congestion), ServerEvent.Kind.CONGESTION_ALERT, "congestion_alert"],
		[ServerEvent.with_crisis_event(crisis), ServerEvent.Kind.CRISIS_EVENT, "crisis_event"],
		[ServerEvent.with_score_tick(_sample_score()), ServerEvent.Kind.SCORE_TICK, "score_tick"],
		[ServerEvent.with_match_end(end), ServerEvent.Kind.MATCH_END, "match_end"],
		[ServerEvent.with_reject(reject), ServerEvent.Kind.REJECT, "reject"],
		[ServerEvent.with_interest_update(update), ServerEvent.Kind.INTEREST_UPDATE, "interest_update"],
		[ServerEvent.with_region_summary(summary), ServerEvent.Kind.REGION_SUMMARY, "region_summary"],
		[ServerEvent.with_welcome(welcome), ServerEvent.Kind.WELCOME, "welcome"],
		[ServerEvent.with_faction_state(state), ServerEvent.Kind.FACTION_STATE, "faction_state"],
	]
	_expect(errors, cases.size() == ServerEvent.Kind.size(), "every ServerEvent kind has a case")
	for entry in cases:
		var event: ServerEvent = entry[0]
		var kind: int = entry[1]
		var key: String = entry[2]
		var dict := event.to_dict()
		_expect(errors, event.kind == kind, "ServerEvent %s kind" % key)
		_expect(errors, dict.size() == 2 and dict["kind"] == kind and dict.has(key) and dict[key] is Dictionary, "ServerEvent %s dict has kind and %s only" % [key, key])
		var back := ServerEvent.from_dict(_json(dict))
		_expect(errors, back.kind == kind, "ServerEvent %s kind back" % key)
		_same(errors, dict, back.to_dict(), "ServerEvent %s" % key)
	var back_welcome := ServerEvent.from_dict(_json(ServerEvent.with_welcome(welcome).to_dict()))
	_expect(errors, back_welcome.welcome != null and back_welcome.welcome.player_id == 3 and back_welcome.faction_state == null, "WELCOME payload only")
	var back_state := ServerEvent.from_dict(_json(ServerEvent.with_faction_state(state).to_dict()))
	_expect(errors, back_state.faction_state != null and is_equal_approx(back_state.faction_state.treasury, 99.0) and back_state.welcome == null, "FACTION_STATE payload only")
	var empty := ServerEvent.from_dict({"kind": ServerEvent.Kind.WELCOME})
	_expect(errors, empty.kind == ServerEvent.Kind.WELCOME and empty.welcome == null, "WELCOME without body stays null")


## to_dict → JSON text → parsed Dictionary, the way the wire and the save file see it.
static func _json(d: Dictionary) -> Dictionary:
	var parsed = JSON.parse_string(JSON.stringify(d))
	if parsed is Dictionary:
		return parsed
	return {}


func _same(errors: Array[String], want: Dictionary, got: Dictionary, label: String) -> void:
	if not _values_equal(want, got):
		errors.append("%s roundtrip: %s != %s" % [label, want, got])


## Deep compare with strict types: an int and a float never match, which catches a
## from_dict that forgot to cast after JSON turned every number into a float.
static func _values_equal(a, b) -> bool:
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not _values_equal(a[key], b[key]):
				return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _values_equal(a[i], b[i]):
				return false
		return true
	if typeof(a) != typeof(b):
		return false
	if a is float:
		return is_equal_approx(a, b)
	return a == b


func _expect(errors: Array[String], cond: bool, message: String) -> void:
	if not cond:
		errors.append(message)

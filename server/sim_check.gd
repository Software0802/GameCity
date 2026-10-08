extends SceneTree

## Headless check of the M2B simulation rules in server/world_state.gd and server/sim/,
## plus the starter town every faction gets on a new round (server/sim/starter_city.gd).
##   godot --headless --path . -s res://server/sim_check.gd
## Every scenario builds its own WorldState at pace 0.01 (one tick = 100 sim seconds,
## so a tier step takes two ticks) unless it says otherwise. Prints SIM_OK plus one
## SIM_PERF line and exits 0, or prints each failure and exits 1.
## Power coverage is the (2 × POWER_RADIUS + 1)² square around a plant; the capacity
## scenarios derive their building counts from POWER_PLANT_CAPACITY.

const WorldStateScript = preload("res://server/world_state.gd")
const GrowthModelScript = preload("res://server/sim/growth_model.gd")

const TEST_PACE := 0.01
const A := SliceConstants.Owner.FACTION_A
const B := SliceConstants.Owner.FACTION_B
const PERF_TICKS := 100
const PERF_SIDE := 64

var _perf_line := ""


func _initialize() -> void:
	var errors: Array[String] = []
	_check_funds(errors)
	_check_free_build(errors)
	_check_tier_up(errors)
	_check_tier_two(errors)
	_check_no_road(errors)
	_check_no_power(errors)
	_check_brownout(errors)
	_check_pollution_cross_owner(errors)
	_check_crisis(errors)
	_check_tax_rate(errors)
	_check_save_roundtrip_timer(errors)
	_check_income(errors)
	_check_event_quantization(errors)
	_check_zone_change(errors)
	_check_starter_city(errors)
	_check_starter_smoke_b(errors)
	_check_perf(errors)
	if errors.is_empty():
		print("SIM_OK")
		print(_perf_line)
		quit(0)
	else:
		for err in errors:
			print("SIM_FAIL %s" % err)
		print(_perf_line)
		quit(1)


# --- Scenarios -----------------------------------------------------------------


## Costs and the INSUFFICIENT_FUNDS reject. The poor faction is built with
## set_treasury_all() (server-core's --start-treasury seam), not by spending down.
func _check_funds(errors: Array[String]) -> void:
	var world = _world()
	_expect(errors, is_equal_approx(world.treasury(A), float(SliceConstants.START_TREASURY)), "start treasury")
	var first_cost: float = world.claim_cost(A)
	var expected_first := float(SliceConstants.COST_CLAIM_BASE) * (1.0 + float(WorldStateScript.SPAWN_SIZE * WorldStateScript.SPAWN_SIZE) * SliceConstants.COST_CLAIM_GROWTH)
	_expect(errors, is_equal_approx(first_cost, expected_first), "first claim cost %s (got %s)" % [expected_first, first_cost])
	_apply_ok(errors, world, A, GameCommand.claim_tile(8, 0), "paid claim")
	_expect(errors, is_equal_approx(world.treasury(A), float(SliceConstants.START_TREASURY) - first_cost), "claim deducts its cost")
	_expect(errors, world.claim_cost(A) > first_cost, "next claim costs more")

	# set_treasury_all: both factions, one cent short of the next claim.
	var cost: float = world.claim_cost(A)
	world.set_treasury_all(cost - 0.01)
	_expect(errors, is_equal_approx(world.treasury(A), cost - 0.01) and is_equal_approx(world.treasury(B), cost - 0.01), "set_treasury_all sets both factions")
	var owned_before: int = world.owned_count(A)
	var rejected: Dictionary = world.apply(A, GameCommand.claim_tile(9, 0))
	_expect(errors, rejected["reason"] == ReasonCode.Id.INSUFFICIENT_FUNDS, "claim reject is INSUFFICIENT_FUNDS (got %d)" % rejected["reason"])
	_expect(errors, rejected["events"].is_empty(), "funds reject has no events")
	_expect(errors, world.tile_at(9, 0).owner == SliceConstants.Owner.NEUTRAL, "rejected tile stays neutral")
	_expect(errors, is_equal_approx(world.treasury(A), cost - 0.01), "rejected claim keeps treasury")
	_expect(errors, world.owned_count(A) == owned_before, "rejected claim keeps owned count")
	_expect(errors, world.faction_states()[A].treasury < cost, "FactionState shows the low treasury")
	# Exactly the price is enough and leaves zero.
	world.set_treasury_all(cost)
	_apply_ok(errors, world, A, GameCommand.claim_tile(9, 0), "claim at exactly the price")
	_expect(errors, is_zero_approx(world.treasury(A)) and world.tile_at(9, 0).owner == A, "exact price accepted, treasury zero")
	# Edges and plants at zero.
	var edge: Dictionary = world.apply(A, GameCommand.add_edge(Vector2i(1, 0), Vector2i(2, 0)))
	_expect(errors, edge["reason"] == ReasonCode.Id.INSUFFICIENT_FUNDS and world.find_edge(Vector2i(1, 0), Vector2i(2, 0)) == null, "edge rejected when poor")
	var plant: Dictionary = world.apply(A, GameCommand.place_power(0, 0))
	_expect(errors, plant["reason"] == ReasonCode.Id.INSUFFICIENT_FUNDS and not world.has_power_source(0, 0), "plant rejected when poor")
	_expect(errors, is_zero_approx(world.treasury(A)), "rejected edge and plant keep treasury")
	world.set_treasury_all(float(SliceConstants.COST_POWER) - 1.0)
	plant = world.apply(A, GameCommand.place_power(0, 0))
	_expect(errors, plant["reason"] == ReasonCode.Id.INSUFFICIENT_FUNDS, "plant rejected one short of COST_POWER")
	world.set_treasury_all(float(SliceConstants.COST_POWER) + float(SliceConstants.COST_EDGE))
	_apply_ok(errors, world, A, GameCommand.place_power(0, 0), "plant at COST_POWER")
	_apply_ok(errors, world, A, GameCommand.add_edge(Vector2i(1, 0), Vector2i(2, 0)), "edge at COST_EDGE")
	_expect(errors, is_zero_approx(world.treasury(A)), "plant and edge charged exactly")
	# Zoning, demolition, and removals stay free at zero.
	var zone: Dictionary = world.apply(A, GameCommand.set_zone(1, 1, SliceConstants.Zone.R))
	_expect(errors, zone["reason"] == ReasonCode.Id.OK and is_zero_approx(world.treasury(A)), "zone is free")
	var demolish: Dictionary = world.apply(A, GameCommand.demolish_own(1, 1))
	_expect(errors, demolish["reason"] == ReasonCode.Id.OK and is_zero_approx(world.treasury(A)), "demolish is free")
	_apply_ok(errors, world, A, GameCommand.remove_edge(Vector2i(1, 0), Vector2i(2, 0)), "remove edge is free")
	_apply_ok(errors, world, A, GameCommand.remove_power(0, 0), "remove plant is free")
	_expect(errors, is_zero_approx(world.treasury(A)), "removals do not refund")
	# Eligibility comes before money: a poor faction still gets the rule reject.
	var spawn_b: Vector2i = WorldStateScript.SPAWN_B
	var steal: Dictionary = world.apply(A, GameCommand.claim_tile(spawn_b.x, spawn_b.y))
	_expect(errors, steal["reason"] == ReasonCode.Id.OPPONENT_IMMUTABLE, "eligibility checked before funds")
	var far: Dictionary = world.apply(A, GameCommand.claim_tile(20, 20))
	_expect(errors, far["reason"] == ReasonCode.Id.NOT_ADJACENT, "adjacency checked before funds")
	# A negative treasury (upkeep) blocks spending the same way.
	world.set_treasury_all(-10.0)
	_expect(errors, world.apply(A, GameCommand.claim_tile(10, 0))["reason"] == ReasonCode.Id.INSUFFICIENT_FUNDS, "negative treasury rejects")
	# set_treasury_all is not part of the save: a restored world keeps its own values.
	world.set_treasury_all(123.5)
	var restored = WorldStateScript.from_save_dict(JSON.parse_string(JSON.stringify(world.to_save_dict())))
	_expect(errors, restored != null and is_equal_approx(restored.treasury(A), 123.5) and is_equal_approx(restored.treasury(B), 123.5), "restored treasuries come from the save")
	_perf_note("start treasury %d buys %d claims in a row from the spawn" % [SliceConstants.START_TREASURY, _claims_until_broke()])


## How many claims START_TREASURY pays for from faction A's spawn (for the hand-back).
func _claims_until_broke() -> int:
	var world = _world()
	var claims := 0
	for x in range(WorldStateScript.SPAWN_SIZE, SliceConstants.MAP_SIZE):
		if world.apply(A, GameCommand.claim_tile(x, 0))["reason"] != ReasonCode.Id.OK:
			break
		claims += 1
	return claims


func _check_free_build(errors: Array[String]) -> void:
	var world = _world()
	world.free_build = true
	_apply_ok(errors, world, A, GameCommand.claim_tile(8, 0), "free claim")
	_apply_ok(errors, world, A, GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 0)), "free edge")
	_apply_ok(errors, world, A, GameCommand.place_power(2, 2), "free plant")
	_expect(errors, is_equal_approx(world.treasury(A), float(SliceConstants.START_TREASURY)), "free_build spends nothing")
	world.free_build = false
	var cost: float = world.claim_cost(A)
	_apply_ok(errors, world, A, GameCommand.claim_tile(9, 0), "paid claim after free_build")
	_expect(errors, is_equal_approx(world.treasury(A), float(SliceConstants.START_TREASURY) - cost), "charging resumes when free_build is off")


## R with road, power, and positive R demand (one C tile) rises to tier 1 on the
## second tick at pace 0.01: 2 × 100 sim seconds ≥ TIER_UP_SECONDS.
func _check_tier_up(errors: Array[String]) -> void:
	var world = _world()
	_build_served_r(errors, world)
	_expect(errors, world.population(A) == SliceConstants.TIER_POP[0] and world.jobs(A) == SliceConstants.TIER_JOBS[0], "tier 0 counters")
	var states: Array = world.faction_states()
	_expect(errors, states[A].demand_r > 0.0, "R demand positive with one C tile (got %s)" % states[A].demand_r)

	var tick1: Array = world.sim_tick(1)
	_expect(errors, world.tile_at(0, 0).building_tier == 0, "no tier after one tick")
	_expect(errors, is_equal_approx(world.satisfaction_raw(0, 0), 1.0 - SliceConstants.TAX_RATE_DEFAULT), "served R satisfaction is the tax penalty (got %s)" % world.satisfaction_raw(0, 0))
	_expect(errors, is_equal_approx(world.tile_at(0, 0).satisfaction, 0.875), "satisfaction quantized to 7/8 (got %s)" % world.tile_at(0, 0).satisfaction)
	_expect(errors, is_equal_approx(world.tier_timer(0, 0), SliceConstants.SIM_TICK_SEC / TEST_PACE), "timer holds one tick of sim seconds (got %s)" % world.tier_timer(0, 0))
	var delta1: ServerEvent = _tile_delta_for(tick1, 0, 0)
	_expect(errors, delta1 != null and is_equal_approx(delta1.tile_delta.satisfaction, 0.875), "tick 1 sends the satisfaction step")

	var tick2: Array = world.sim_tick(2)
	_expect(errors, world.tile_at(0, 0).building_tier == 1, "served R reaches tier 1 on tick 2")
	var delta2: ServerEvent = _tile_delta_for(tick2, 0, 0)
	_expect(errors, delta2 != null and delta2.tile_delta.building_tier == 1, "tier change sends a TileDelta")
	_expect(errors, is_zero_approx(world.tier_timer(0, 0)), "timer resets after the step")
	_expect(errors, world.population(A) == SliceConstants.TIER_POP[1], "population follows the tier")
	# The upgraded tile now loads its edge: tier 1 + tier 0 = 1 → 0.1 → one 1/8 step.
	var congestion: ServerEvent = _first_kind(tick2, ServerEvent.Kind.CONGESTION_ALERT)
	_expect(errors, congestion != null and is_equal_approx(congestion.congestion_alert.congestion, 0.125), "tier step crosses a congestion step")
	_expect(errors, world.find_edge(Vector2i(0, 0), Vector2i(1, 0)) != null and is_equal_approx(world.find_edge(Vector2i(0, 0), Vector2i(1, 0)).congestion, 0.125), "edge stores quantized congestion")
	# Demand flips: pop 3 > jobs 2 closes the R gate (0.3 × 0.9 = 0.27 ≤ SAT_DOWN),
	# so the tile falls back after TIER_DOWN_SECONDS while C grows on the open gate.
	world.sim_tick(3)
	world.sim_tick(4)
	_expect(errors, world.tile_at(0, 0).building_tier == 0 and world.tile_at(1, 0).building_tier == 1, "closed R gate drops the tier while C rises")


## R on its own road with two C tiles elsewhere keeps a positive R gate and a
## lightly loaded edge all the way to tier 2 (two steps, four ticks).
func _check_tier_two(errors: Array[String]) -> void:
	var world = _world()
	_apply_ok(errors, world, A, GameCommand.set_zone(0, 0, SliceConstants.Zone.R), "R")
	_apply_ok(errors, world, A, GameCommand.add_edge(Vector2i(0, 0), Vector2i(0, 1)), "R road to an empty lot")
	_apply_ok(errors, world, A, GameCommand.set_zone(4, 0, SliceConstants.Zone.C), "C one")
	_apply_ok(errors, world, A, GameCommand.set_zone(4, 1, SliceConstants.Zone.C), "C two")
	_apply_ok(errors, world, A, GameCommand.add_edge(Vector2i(4, 0), Vector2i(4, 1)), "C road")
	_apply_ok(errors, world, A, GameCommand.place_power(2, 2), "plant")
	var reached := _ticks_until(world, 0, 0, 2, 4)
	_expect(errors, reached == 4, "R reaches tier 2 on tick 4 (got %d)" % reached)
	_expect(errors, world.population(A) == SliceConstants.TIER_POP[2], "tier 2 population")
	_expect(errors, is_equal_approx(world.find_edge(Vector2i(0, 0), Vector2i(0, 1)).congestion, 0.25), "tier 2 on an otherwise empty edge loads it to 2/10 → 2/8")
	# pop 8 > jobs 4 now closes the R gate: the down timer runs, no up timer ever does.
	world.sim_tick(5)
	_expect(errors, world.tile_at(0, 0).building_tier == 2 and world.tier_timer(0, 0) <= 0.0, "max tier never accumulates an up timer")


func _check_no_road(errors: Array[String]) -> void:
	var world = _world()
	_build_served_r(errors, world)
	_apply_ok(errors, world, A, GameCommand.remove_edge(Vector2i(0, 0), Vector2i(1, 0)), "remove the road")
	for tick in 4:
		world.sim_tick(tick + 1)
	_expect(errors, world.tile_at(0, 0).building_tier == 0, "R without a road stays tier 0")
	_expect(errors, is_zero_approx(world.satisfaction_raw(0, 0)) and is_zero_approx(world.tile_at(0, 0).satisfaction), "R without a road has zero satisfaction")


func _check_no_power(errors: Array[String]) -> void:
	var world = _world()
	_build_served_r(errors, world)
	_apply_ok(errors, world, A, GameCommand.remove_power(2, 2), "remove the plant")
	_expect(errors, not world.tile_at(0, 0).power_covered, "coverage gone")
	for tick in 4:
		world.sim_tick(tick + 1)
	_expect(errors, world.tile_at(0, 0).building_tier == 0, "R without power stays tier 0")
	_expect(errors, is_zero_approx(world.satisfaction_raw(0, 0)), "R without power has zero satisfaction")


## POWER_PLANT_CAPACITY + 1 tier-0 buildings inside one plant's square load it one
## over capacity. The plant sits at (3,3) so its square holds the whole spawn block.
func _check_brownout(errors: Array[String]) -> void:
	var world = _world()
	world.free_build = true
	var plant := Vector2i(3, 3)
	var cap := SliceConstants.POWER_PLANT_CAPACITY
	_apply_ok(errors, world, A, GameCommand.place_power(plant.x, plant.y), "plant")
	var inside := _square_in_spawn(plant, SliceConstants.POWER_RADIUS)
	_expect(errors, inside.size() == WorldStateScript.SPAWN_SIZE * WorldStateScript.SPAWN_SIZE - 1, "plant at (3,3) covers the whole spawn block (%d tiles)" % inside.size())
	if inside.size() <= cap:
		errors.append("brownout scenario needs more than POWER_PLANT_CAPACITY=%d tiles under one plant, the spawn offers %d" % [cap, inside.size()])
		return
	var alerted := false
	var placed := 0
	for cell in inside:
		if placed >= cap + 1:
			break
		var result: Dictionary = world.apply(A, GameCommand.set_zone(cell.x, cell.y, SliceConstants.Zone.C))
		_expect(errors, result["reason"] == ReasonCode.Id.OK, "zone C at %s" % cell)
		placed += 1
		var load: int = world.plant_load(plant.x, plant.y)
		_expect(errors, load == placed, "plant load counts tier+1 per building (%d after %d)" % [load, placed])
		var brown := load > cap
		_expect(errors, world.tile_at(cell.x, cell.y).brownout == brown, "brownout flag after %d buildings" % placed)
		for event in result["events"]:
			if event.kind == ServerEvent.Kind.POWER_ALERT and event.power_alert.brownout and event.power_alert.x == plant.x and event.power_alert.y == plant.y:
				alerted = true
		if brown:
			_expect(errors, _tile_delta_for(result["events"], plant.x, plant.y) != null and _tile_delta_for(result["events"], plant.x, plant.y).tile_delta.brownout, "brownout TileDelta reaches the plant tile")
	_expect(errors, alerted, "PowerAlert(brownout=true) sent when the plant overloads")
	var outside := Vector2i(plant.x + SliceConstants.POWER_RADIUS + 1, plant.y + SliceConstants.POWER_RADIUS + 1)
	_expect(errors, world.tile_at(outside.x, outside.y).brownout == false and not world.tile_at(outside.x, outside.y).power_covered, "tile outside the square untouched")
	_expect(errors, world.tile_at(plant.x + SliceConstants.POWER_RADIUS, plant.y + SliceConstants.POWER_RADIUS).power_covered, "square corner is covered")
	var states: Array = world.faction_states()
	_expect(errors, states[A].power_capacity == cap and states[A].power_load == cap + 1, "FactionState power capacity and load")
	# An overloaded plant gives no actual power: served R stays dark and does not grow.
	_apply_ok(errors, world, A, GameCommand.add_edge(Vector2i(3, 0), Vector2i(4, 0)), "road for the brownout R")
	_apply_ok(errors, world, A, GameCommand.set_zone(3, 0, SliceConstants.Zone.R), "R under brownout")
	for tick in 3:
		world.sim_tick(tick + 1)
	_expect(errors, is_zero_approx(world.satisfaction_raw(3, 0)) and world.tile_at(3, 0).building_tier == 0, "brownout R has zero satisfaction")
	var summary: RegionSummary = world.summary_for(InterestId.new(0, 0))
	_expect(errors, summary.brownout and summary.power_alert and summary.population == SliceConstants.TIER_POP[0] and summary.crisis == false, "RegionSummary reports brownout, shortage, population")
	# Demolishing two buildings clears it and sends the all-clear.
	var cleared := false
	for cell in inside.slice(0, 2):
		var result: Dictionary = world.apply(A, GameCommand.demolish_own(cell.x, cell.y))
		for event in result["events"]:
			if event.kind == ServerEvent.Kind.POWER_ALERT and not event.power_alert.brownout and event.power_alert.x == plant.x:
				cleared = true
	_expect(errors, cleared and not world.tile_at(plant.x, plant.y).brownout, "brownout clears when the load drops")


## Three A industrial tiles at the spawn corner pollute a B residential tile across
## the border; its satisfaction is lower than B's identical control tile.
func _check_pollution_cross_owner(errors: Array[String]) -> void:
	var world = _world()
	world.free_build = true
	var spawn_b: Vector2i = WorldStateScript.SPAWN_B
	var side := WorldStateScript.SPAWN_SIZE
	# B walks a claim chain from its spawn to the corner next to A's spawn.
	_claim_line(errors, world, B, Vector2i(spawn_b.x, spawn_b.y - 1), Vector2i(0, -1), spawn_b.y - side)
	_claim_line(errors, world, B, Vector2i(spawn_b.x - 1, side), Vector2i(-1, 0), spawn_b.x - side)
	_apply_ok(errors, world, B, GameCommand.claim_tile(side, side - 1), "B claims the border tile")
	_apply_ok(errors, world, B, GameCommand.claim_tile(side + 1, side - 1), "B claims its C tile")
	var victim := Vector2i(side, side - 1)
	_apply_ok(errors, world, B, GameCommand.set_zone(victim.x, victim.y, SliceConstants.Zone.R), "B R at the border")
	_apply_ok(errors, world, B, GameCommand.set_zone(side + 1, side - 1, SliceConstants.Zone.C), "B C at the border")
	_apply_ok(errors, world, B, GameCommand.add_edge(victim, Vector2i(side + 1, side - 1)), "B border road")
	_apply_ok(errors, world, B, GameCommand.place_power(side + 1, side), "B border plant")
	# B control block at its own spawn, same recipe, far from any industry.
	_apply_ok(errors, world, B, GameCommand.set_zone(spawn_b.x, spawn_b.y, SliceConstants.Zone.R), "B control R")
	_apply_ok(errors, world, B, GameCommand.set_zone(spawn_b.x + 1, spawn_b.y, SliceConstants.Zone.C), "B control C")
	_apply_ok(errors, world, B, GameCommand.add_edge(spawn_b, spawn_b + Vector2i(1, 0)), "B control road")
	_apply_ok(errors, world, B, GameCommand.place_power(spawn_b.x + 2, spawn_b.y + 2), "B control plant")
	# A industry hugging the corner.
	var sources: Array[Vector2i] = [Vector2i(side - 1, side - 1), Vector2i(side - 1, side - 2), Vector2i(side - 2, side - 1)]
	for source in sources:
		_apply_ok(errors, world, A, GameCommand.set_zone(source.x, source.y, SliceConstants.Zone.I), "A industry at %s" % source)
	_expect(errors, world.tile_at(victim.x, victim.y).owner == B, "victim is owned by B")
	var raw: float = world.pollution_raw(victim.x, victim.y)
	_expect(errors, raw > 0.0, "pollution crosses the owner border (got %s)" % raw)
	_expect(errors, world.tile_at(victim.x, victim.y).pollution > 0.0, "quantized pollution is on the B tile")
	var neutral := Vector2i(side - 1, side + 2)
	_expect(errors, world.tile_at(neutral.x, neutral.y).owner == SliceConstants.Owner.NEUTRAL and world.pollution_raw(neutral.x, neutral.y) > 0.0, "pollution reaches a neutral tile too")
	_expect(errors, is_zero_approx(world.pollution_raw(side - 1, side + 3)), "pollution stops at POLLUTION_RADIUS")
	# Linear falloff: the source tile itself is more polluted than one step away.
	_expect(errors, world.pollution_raw(side - 1, side - 1) > raw, "pollution peaks at the source")
	_expect(errors, world.summary_for(InterestId.from_tile(side - 1, side - 1)).pollution_avg > 0.0 and is_zero_approx(world.summary_for(InterestId.from_tile(spawn_b.x, spawn_b.y)).pollution_avg), "RegionSummary pollution_avg follows the field")
	world.sim_tick(1)
	var polluted: float = world.satisfaction_raw(victim.x, victim.y)
	var control: float = world.satisfaction_raw(spawn_b.x, spawn_b.y)
	_expect(errors, control > 0.0 and polluted < control, "pollution lowers satisfaction across the border (%s < %s)" % [polluted, control])
	_expect(errors, world.tile_at(victim.x, victim.y).satisfaction < world.tile_at(spawn_b.x, spawn_b.y).satisfaction, "quantized satisfaction shows the drop")
	# Removing the industry removes the field exactly (integer mass, no drift).
	for source in sources:
		_apply_ok(errors, world, A, GameCommand.set_zone(source.x, source.y, SliceConstants.Zone.NONE), "clear industry at %s" % source)
	_expect(errors, is_zero_approx(world.pollution_raw(victim.x, victim.y)) and is_zero_approx(world.tile_at(victim.x, victim.y).pollution), "pollution returns to zero")


## POWER_PLANT_CAPACITY tier-0 buildings under one plant fit exactly, but not in
## POWER_PLANT_CAPACITY × CRISIS_CAPACITY_FACTOR.
func _check_crisis(errors: Array[String]) -> void:
	var world = _world()
	world.free_build = true
	var plant := Vector2i(3, 3)
	_apply_ok(errors, world, A, GameCommand.place_power(plant.x, plant.y), "plant")
	var inside := _square_in_spawn(plant, SliceConstants.POWER_RADIUS)
	var load: int = SliceConstants.POWER_PLANT_CAPACITY
	if inside.size() < load:
		errors.append("crisis scenario needs POWER_PLANT_CAPACITY=%d tiles under one plant, the spawn offers %d" % [load, inside.size()])
		return
	for cell in inside.slice(0, load):
		_apply_ok(errors, world, A, GameCommand.set_zone(cell.x, cell.y, SliceConstants.Zone.C), "C at %s" % cell)
	world.sim_tick(1)
	_expect(errors, not world.tile_at(plant.x, plant.y).brownout and world.plant_load(plant.x, plant.y) == load, "plant copes before the storm")
	_expect(errors, not _has_kind(world.sim_tick(2), ServerEvent.Kind.CRISIS_EVENT), "no CrisisEvent without set_crisis")

	var now := int(Time.get_unix_time_from_system())
	world.set_crisis(true)
	_expect(errors, world.crisis_active and world.crisis_ends_at_unix >= now + SliceConstants.CRISIS_DURATION_SEC, "set_crisis(true) sets the end time")
	_expect(errors, world.plant_capacity() == int(SliceConstants.POWER_PLANT_CAPACITY * SliceConstants.CRISIS_CAPACITY_FACTOR), "capacity halves during the storm")
	var storm: Array = world.sim_tick(3)
	var crisis: ServerEvent = _first_kind(storm, ServerEvent.Kind.CRISIS_EVENT)
	_expect(errors, crisis != null and crisis.crisis_event.active and crisis.crisis_event.kind == CrisisEvent.KIND_GRID_STORM, "CrisisEvent grid_storm active")
	_expect(errors, crisis != null and crisis.crisis_event.ends_at_unix == world.crisis_ends_at_unix, "CrisisEvent carries ends_at_unix")
	_expect(errors, world.tile_at(plant.x, plant.y).brownout and world.tile_at(inside[0].x, inside[0].y).brownout, "storm browns out the plant's radius")
	var alert: ServerEvent = _first_kind(storm, ServerEvent.Kind.POWER_ALERT)
	_expect(errors, alert != null and alert.power_alert.brownout, "storm sends PowerAlert(brownout=true)")
	_expect(errors, _count_kind(storm, ServerEvent.Kind.CRISIS_EVENT) == 1 and not _has_kind(world.sim_tick(4), ServerEvent.Kind.CRISIS_EVENT), "CrisisEvent sent once")
	var states: Array = world.faction_states()
	_expect(errors, states[A].power_capacity == world.plant_capacity() and states[A].power_load == load, "FactionState reflects storm capacity")

	world.set_crisis(false)
	_expect(errors, not world.crisis_active and world.crisis_ends_at_unix == 0, "set_crisis(false) clears")
	var calm: Array = world.sim_tick(5)
	var over: ServerEvent = _first_kind(calm, ServerEvent.Kind.CRISIS_EVENT)
	_expect(errors, over != null and not over.crisis_event.active and over.crisis_event.ends_at_unix == 0, "CrisisEvent inactive after the storm")
	_expect(errors, not world.tile_at(plant.x, plant.y).brownout, "brownout clears after the storm")
	var custom = _world()
	custom.set_crisis(true, 1234567)
	_expect(errors, custom.crisis_ends_at_unix == 1234567, "explicit ends_at_unix is kept")


func _check_tax_rate(errors: Array[String]) -> void:
	var world = _world()
	for bad in [SliceConstants.TAX_RATE_MAX + 0.01, SliceConstants.TAX_RATE_MIN - 0.01, 2.0, INF, NAN]:
		var result: Dictionary = world.apply(A, GameCommand.set_tax_rate(bad))
		_expect(errors, result["reason"] == ReasonCode.Id.INVALID_RATE and result["events"].is_empty(), "tax %s rejected INVALID_RATE" % bad)
	_expect(errors, is_equal_approx(world.tax_rate(A), SliceConstants.TAX_RATE_DEFAULT), "rejected rates leave the tax untouched")
	_expect(errors, GameCommand.set_tax_rate(SliceConstants.TAX_RATE_MAX + 0.01).validate_shape() == ReasonCode.Id.INVALID_RATE, "validate_shape rejects the range")
	var ok: Dictionary = world.apply(A, GameCommand.set_tax_rate(SliceConstants.TAX_RATE_MAX))
	_expect(errors, ok["reason"] == ReasonCode.Id.OK and is_equal_approx(world.tax_rate(A), SliceConstants.TAX_RATE_MAX), "max tax accepted")
	_expect(errors, is_equal_approx(world.tax_rate(B), SliceConstants.TAX_RATE_DEFAULT), "tax is per faction")
	var nobody: Dictionary = world.apply(SliceConstants.Owner.NEUTRAL, GameCommand.set_tax_rate(0.2))
	_expect(errors, nobody["reason"] == ReasonCode.Id.NOT_AUTHENTICATED and nobody["events"].is_empty(), "a command without a faction is NOT_AUTHENTICATED")
	_expect(errors, is_equal_approx(world.faction_states()[A].tax_rate, SliceConstants.TAX_RATE_MAX), "FactionState carries the rate")

	# Same served R, two tax rates: the higher rate lowers satisfaction linearly.
	var low = _world()
	_build_served_r(errors, low)
	var high = _world()
	_build_served_r(errors, high)
	_apply_ok(errors, high, A, GameCommand.set_tax_rate(SliceConstants.TAX_RATE_MAX), "high tax")
	low.sim_tick(1)
	high.sim_tick(1)
	var sat_low: float = low.satisfaction_raw(0, 0)
	var sat_high: float = high.satisfaction_raw(0, 0)
	_expect(errors, is_equal_approx(sat_low, 1.0 - SliceConstants.TAX_RATE_DEFAULT) and is_equal_approx(sat_high, 1.0 - SliceConstants.TAX_RATE_MAX), "tax penalty is 1 − rate (%s, %s)" % [sat_low, sat_high])
	_expect(errors, high.tile_at(0, 0).satisfaction < low.tile_at(0, 0).satisfaction, "high tax lowers the quantized satisfaction")
	# Higher tax also raises income per population.
	var income_low: float = low.faction_states()[A].income_per_sec
	var income_high: float = high.faction_states()[A].income_per_sec
	_expect(errors, income_high > income_low, "high tax raises income (%s > %s)" % [income_high, income_low])


## One tick, save, restore, one more tick: the tier step lands on the restored world.
func _check_save_roundtrip_timer(errors: Array[String]) -> void:
	var world = _world()
	_build_served_r(errors, world)
	_apply_ok(errors, world, A, GameCommand.set_tax_rate(0.2), "tax before save")
	world.sim_tick(1)
	world.set_crisis(true)
	var timer_before: float = world.tier_timer(0, 0)
	_expect(errors, timer_before > 0.0, "timer running before save")
	var save: Dictionary = world.to_save_dict()
	for key in ["pace", "factions", "tier_timers", "crisis_pending", "crisis_ends_at_unix"]:
		_expect(errors, save.has(key), "save has %s" % key)
	_expect(errors, save["tier_timers"].size() >= 1 and int(save["tier_timers"][0][0]) == SliceConstants.tile_id(0, 0), "tier_timers stores the R tile")
	var parsed = JSON.parse_string(JSON.stringify(save))
	var restored = WorldStateScript.from_save_dict(parsed)
	if restored == null:
		errors.append("from_save_dict returned null")
		return
	_expect(errors, is_equal_approx(restored.pace, TEST_PACE), "pace restored")
	_expect(errors, is_equal_approx(restored.tier_timer(0, 0), timer_before), "timer restored (%s vs %s)" % [restored.tier_timer(0, 0), timer_before])
	_expect(errors, is_equal_approx(restored.treasury(A), world.treasury(A)) and is_equal_approx(restored.tax_rate(A), 0.2), "treasury and tax restored")
	_expect(errors, restored.population(A) == world.population(A) and restored.jobs(A) == world.jobs(A), "counters rebuilt from tiles")
	_expect(errors, restored.crisis_active and restored.crisis_ends_at_unix == world.crisis_ends_at_unix and restored.plant_capacity() == world.plant_capacity(), "crisis restored")
	_expect(errors, restored.tile_at(0, 0).power_covered and restored.find_edge(Vector2i(0, 0), Vector2i(1, 0)) != null, "structure restored")
	_expect(errors, JSON.stringify(restored.to_save_dict()) == JSON.stringify(save), "second save text equals first")
	var next: Array = restored.sim_tick(2)
	_expect(errors, restored.tile_at(0, 0).building_tier == 1, "restored timer continues: tier 1 after one more tick")
	_expect(errors, _has_kind(next, ServerEvent.Kind.CRISIS_EVENT), "pending CrisisEvent survives the save")
	var control = _world()
	_build_served_r(errors, control)
	control.sim_tick(1)
	_expect(errors, control.tile_at(0, 0).building_tier == 0, "a fresh world needs two ticks")


## Income per second matches the formula and the treasury moves by it each tick.
func _check_income(errors: Array[String]) -> void:
	var world = _world()
	_build_served_r(errors, world)
	world.sim_tick(1)
	world.sim_tick(2)
	_expect(errors, world.tile_at(0, 0).building_tier == 1, "income scenario at tier 1")
	var pop: int = world.population(A)
	var jobs: int = world.jobs(A)
	var rate: float = world.tax_rate(A)
	var base := float(pop) * rate * SliceConstants.INCOME_PER_POP_PER_SEC + float(jobs) * SliceConstants.INCOME_PER_JOB_PER_SEC - 1.0 * SliceConstants.UPKEEP_POWER_PER_SEC
	var expected := base / TEST_PACE
	var state: FactionState = world.faction_states()[A]
	_expect(errors, state.population == pop and state.jobs == jobs and state.technicians == 0, "FactionState counters")
	_expect(errors, is_equal_approx(state.income_per_sec, expected), "income_per_sec %s (got %s)" % [expected, state.income_per_sec])
	_expect(errors, is_equal_approx(state.demand_r, float(jobs - pop) / float(jobs + pop)), "demand_r normalized")
	_expect(errors, is_equal_approx(state.demand_c, float(pop - jobs) / float(pop + jobs)) and is_equal_approx(state.demand_i, 1.0), "demand_c and demand_i normalized")
	_expect(errors, state.power_capacity == SliceConstants.POWER_PLANT_CAPACITY and state.power_load == 3, "power load counts tier+1 of R(1) and C(0)")
	var before: float = world.treasury(A)
	world.sim_tick(3)
	_expect(errors, is_equal_approx(world.treasury(A), before + expected * SliceConstants.SIM_TICK_SEC), "treasury moves by income × SIM_TICK_SEC")
	# At pace 1.0 the per-second income is the bare formula.
	var slow = _world(1.0)
	_build_served_r(errors, slow)
	var slow_base := float(slow.population(A)) * SliceConstants.TAX_RATE_DEFAULT * SliceConstants.INCOME_PER_POP_PER_SEC + float(slow.jobs(A)) * SliceConstants.INCOME_PER_JOB_PER_SEC - SliceConstants.UPKEEP_POWER_PER_SEC
	_expect(errors, is_equal_approx(slow.faction_states()[A].income_per_sec, slow_base), "pace 1.0 income is the formula")
	_expect(errors, is_equal_approx(world.faction_states()[B].treasury, float(SliceConstants.START_TREASURY)), "idle faction earns nothing")
	# Score: pop, treasury, owned tiles, normalized shares.
	var tick: ScoreTick = world.score(42)
	_expect(errors, tick.seconds_remaining == 42 and tick.factions.size() == 2, "score carries seconds_remaining")
	_expect(errors, is_equal_approx(tick.factions[A].pop_raw, float(pop)) and is_equal_approx(tick.factions[A].fiscal_raw, world.treasury(A)) and is_equal_approx(tick.factions[A].control_raw, float(world.owned_count(A))), "score raw terms")
	_expect(errors, is_equal_approx(tick.factions[A].pop, 1.0) and is_equal_approx(tick.factions[A].control, 0.5), "score shares normalized")


## At pace 1.0 nothing crosses a step on the second tick: no TileDelta goes out,
## and every tick sends at most one TileDelta per tile.
func _check_event_quantization(errors: Array[String]) -> void:
	var world = _world(1.0)
	_build_served_r(errors, world)
	var tick1: Array = world.sim_tick(1)
	var ids: Dictionary = {}
	for event in tick1:
		if event.kind == ServerEvent.Kind.TILE_DELTA:
			_expect(errors, not ids.has(event.tile_delta.id), "one TileDelta per tile per tick")
			ids[event.tile_delta.id] = true
	_expect(errors, ids.has(SliceConstants.tile_id(0, 0)) and ids.has(SliceConstants.tile_id(1, 0)), "first tick sends the satisfaction steps")
	_expect(errors, is_equal_approx(_tile_delta_for(tick1, 1, 0).tile_delta.satisfaction, 0.25), "closed demand gate shows as 0.3 × 0.9 → 2/8 (got %s)" % _tile_delta_for(tick1, 1, 0).tile_delta.satisfaction)
	var tick2: Array = world.sim_tick(2)
	_expect(errors, _count_kind(tick2, ServerEvent.Kind.TILE_DELTA) == 0, "no TileDelta while nothing crosses a step (got %d)" % _count_kind(tick2, ServerEvent.Kind.TILE_DELTA))
	_expect(errors, _count_kind(tick2, ServerEvent.Kind.CONGESTION_ALERT) == 0 and _count_kind(tick2, ServerEvent.Kind.POWER_ALERT) == 0, "no alerts while nothing changes")
	_expect(errors, _count_kind(tick2, ServerEvent.Kind.SCORE_TICK) == 1, "ScoreTick every tick")
	_expect(errors, world.tier_timer(0, 0) > world.tier_timer(1, 0), "timers still accumulate silently")
	# Pollution: quantized value only moves on a step. One tier-0 factory alone puts
	# 1/44 on a tile three steps away: raw > 0 but quantized 0, so no TileDelta there.
	var result: Dictionary = world.apply(A, GameCommand.set_zone(4, 4, SliceConstants.Zone.I))
	_expect(errors, world.pollution_raw(4, 7) > 0.0 and is_zero_approx(world.tile_at(4, 7).pollution), "sub-step pollution is not quantized up")
	_expect(errors, _tile_delta_for(result["events"], 4, 7) == null and _tile_delta_for(result["events"], 4, 4) != null, "TileDelta only where the pollution step moved")


## Zoning a different type starts a new tier-0 building; demolition keeps the zone.
func _check_zone_change(errors: Array[String]) -> void:
	var world = _world()
	_build_served_r(errors, world)
	world.sim_tick(1)
	world.sim_tick(2)
	_expect(errors, world.tile_at(0, 0).building_tier == 1, "zone change scenario at tier 1")
	var same: Dictionary = world.apply(A, GameCommand.set_zone(0, 0, SliceConstants.Zone.R))
	_expect(errors, same["reason"] == ReasonCode.Id.OK and world.tile_at(0, 0).building_tier == 1, "same zone keeps the building")
	_apply_ok(errors, world, A, GameCommand.set_zone(0, 0, SliceConstants.Zone.C), "re-zone to C")
	_expect(errors, world.tile_at(0, 0).building_tier == 0 and world.population(A) == 0 and world.jobs(A) == 2 * SliceConstants.TIER_JOBS[0], "re-zoning resets the tier and moves the counters")
	_apply_ok(errors, world, A, GameCommand.demolish_own(0, 0), "demolish")
	_expect(errors, world.tile_at(0, 0).zone == SliceConstants.Zone.C and not world.tile_at(0, 0).has_building and world.jobs(A) == SliceConstants.TIER_JOBS[0], "demolition keeps the zone and drops the jobs")
	_expect(errors, is_zero_approx(world.tile_at(0, 0).satisfaction), "demolished tile has zero satisfaction")
	_apply_ok(errors, world, A, GameCommand.set_zone(0, 0, SliceConstants.Zone.C), "rebuild")
	_expect(errors, world.tile_at(0, 0).has_building and world.tile_at(0, 0).building_tier == 0, "same zone on a demolished lot rebuilds at tier 0")


## The starter town (server/sim/starter_city.gd) both factions get on a new round:
## one plant whose square covers the whole block, the 田 roads with lanes, 16
## tier-1 buildings (9 R / 4 C / 3 I) on road tiles, nothing charged, timers at 0.
## At pace 0.01 every R and C lot reaches tier 2 on tick 2 while the factories stay
## at tier 1 (their own pollution keeps them under SAT_UP); through tick 20 nothing
## falls back or browns out. The load figures are what POWER_PLANT_CAPACITY has to
## carry: the town at the start, the town fully grown, and the storm must still bite.
func _check_starter_city(errors: Array[String]) -> void:
	var world = _world()
	_expect(errors, world.seed_starter_cities() == 2, "seed_starter_cities seeds both blocks")
	_expect(errors, world.seed_starter_cities() == 0, "second seed call is a no-op")
	var cap := SliceConstants.POWER_PLANT_CAPACITY
	for faction in [A, B]:
		var plan = WorldStateScript.starter_plan(faction)
		var origin: Vector2i = plan.origin
		var tag := "F%d" % faction
		_expect(errors, is_equal_approx(world.treasury(faction), float(SliceConstants.START_TREASURY)), "%s starter town is free" % tag)
		_expect(errors, plan.building_count() >= 14, "%s plan holds at least 14 buildings (got %d)" % [tag, plan.building_count()])
		_expect(errors, plan.edges.size() >= 12, "%s plan holds at least 12 edges (got %d)" % [tag, plan.edges.size()])
		_expect(errors, plan.power_load() <= cap, "%s starter load %d must fit POWER_PLANT_CAPACITY %d" % [tag, plan.power_load(), cap])
		_expect(errors, _grown_load(plan) <= cap, "%s grown starter load %d must fit POWER_PLANT_CAPACITY %d" % [tag, _grown_load(plan), cap])
		_expect(errors, int(floor(float(cap) * SliceConstants.CRISIS_CAPACITY_FACTOR)) < _grown_load(plan), "%s grid storm must bite the grown town (%d vs %d)" % [tag, int(floor(float(cap) * SliceConstants.CRISIS_CAPACITY_FACTOR)), _grown_load(plan)])
		var plants := 0
		var tier_one := 0
		var covered_buildings := true
		var covered_block := true
		var on_road := true
		var timers_zero := true
		var bare_road_tiles := 0
		for y in WorldStateScript.SPAWN_SIZE:
			for x in WorldStateScript.SPAWN_SIZE:
				var tile: TileDelta = world.tile_at(origin.x + x, origin.y + y)
				_expect(errors, tile.owner == faction, "%s block tile %s stays owned" % [tag, Vector2i(x, y)])
				if world.has_power_source(tile.x, tile.y):
					plants += 1
				if not tile.power_covered:
					covered_block = false
				if tile.has_building:
					if tile.building_tier == 1:
						tier_one += 1
					if not tile.power_covered:
						covered_buildings = false
					if not _has_road(world, tile.x, tile.y):
						on_road = false
					if not is_zero_approx(world.tier_timer(tile.x, tile.y)):
						timers_zero = false
				elif _has_road(world, tile.x, tile.y):
					bare_road_tiles += 1
		_expect(errors, plants == 1, "%s block has one plant (got %d)" % [tag, plants])
		_expect(errors, tier_one >= 14, "%s block has at least 14 tier-1 buildings (got %d)" % [tag, tier_one])
		_expect(errors, covered_buildings and covered_block, "%s whole block is power_covered" % tag)
		_expect(errors, on_road, "%s every building is on a road" % tag)
		_expect(errors, timers_zero, "%s tier timers start at 0" % tag)
		_expect(errors, bare_road_tiles >= plan.empty_lots.size() + 3, "%s leaves road tiles free for the player" % tag)
		_expect(errors, world.edges_in_block(InterestId.from_tile(origin.x, origin.y)).size() >= 12, "%s block has at least 12 edges" % tag)
		_expect(errors, _brownout_count(world, origin) == 0, "%s no brownout after seeding" % tag)
		var state: FactionState = world.faction_states()[faction]
		_expect(errors, state.population > 0 and state.jobs > state.population, "%s population %d > 0 and jobs %d exceed it" % [tag, state.population, state.jobs])
		_expect(errors, state.demand_r > 0.0 and state.demand_c > 0.0 and state.demand_i > 0.0, "%s every demand gate open at the start (%s %s %s)" % [tag, state.demand_r, state.demand_c, state.demand_i])
		_expect(errors, state.power_load == plan.power_load() and state.power_capacity == cap, "%s FactionState power %d/%d" % [tag, state.power_load, state.power_capacity])
	var plan_a = WorldStateScript.starter_plan(A)
	var r_lots: int = plan_a.count_zone(SliceConstants.Zone.R)
	var c_lots: int = plan_a.count_zone(SliceConstants.Zone.C)
	var i_lots: int = plan_a.count_zone(SliceConstants.Zone.I)
	# Growth: tick 1 keeps every tier, tick 2 lifts every R and C lot, nothing moves after.
	var tick1: Array = world.sim_tick(1)
	_expect(errors, _tier_histogram(world, WorldStateScript.SPAWN_A) == [0, plan_a.building_count(), 0], "tick 1 keeps every starter building at tier 1")
	_expect(errors, _count_kind(tick1, ServerEvent.Kind.POWER_ALERT) == 0, "tick 1 sends no PowerAlert")
	for lot in plan_a.lots:
		var cell: Vector2i = lot[0]
		var sat: float = world.satisfaction_raw(cell.x, cell.y)
		if int(lot[1]) == SliceConstants.Zone.I:
			_expect(errors, sat > SliceConstants.SAT_DOWN and sat < SliceConstants.SAT_UP, "factory %s sits between SAT_DOWN and SAT_UP (%.3f)" % [cell, sat])
		else:
			_expect(errors, sat >= SliceConstants.SAT_UP, "lot %s satisfied enough to grow (%.3f)" % [cell, sat])
	world.sim_tick(2)
	var grown := [0, i_lots, r_lots + c_lots]
	_expect(errors, _tier_histogram(world, WorldStateScript.SPAWN_A) == grown and _tier_histogram(world, WorldStateScript.SPAWN_B) == grown, "tick 2 lifts every R and C lot to tier 2 in both blocks (A %s B %s)" % [_tier_histogram(world, WorldStateScript.SPAWN_A), _tier_histogram(world, WorldStateScript.SPAWN_B)])
	_expect(errors, world.population(A) == r_lots * SliceConstants.TIER_POP[2], "grown population")
	var income_grown: float = world.faction_states()[A].income_per_sec * TEST_PACE
	_expect(errors, income_grown > 0.0, "grown starter town earns money (%.3f/s at pace 1.0)" % income_grown)
	for tick in range(3, 21):
		world.sim_tick(tick)
		for faction in [A, B]:
			var origin: Vector2i = WorldStateScript.starter_plan(faction).origin
			_expect(errors, _tier_histogram(world, origin) == grown, "tick %d F%d keeps the grown town (%s)" % [tick, faction, _tier_histogram(world, origin)])
			_expect(errors, _brownout_count(world, origin) == 0, "tick %d F%d no brownout" % [tick, faction])
			var state: FactionState = world.faction_states()[faction]
			_expect(errors, state.demand_r > 0.0 and state.demand_c > 0.0 and state.demand_i > 0.0, "tick %d F%d gates open" % [tick, faction])
	# The legacy smoke host still gets its three commands accepted on the town.
	_apply_ok(errors, world, A, GameCommand.set_zone(0, 0, SliceConstants.Zone.R), "smoke host zone (0,0)")
	_apply_ok(errors, world, A, GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 0)), "smoke host edge on an existing road")
	world.free_build = true
	_apply_ok(errors, world, A, GameCommand.claim_tile(WorldStateScript.SPAWN_SIZE, 0), "smoke host claim (8,0)")
	# The empty lots grow when zoned: one more R on a lane reaches tier 1 in two ticks.
	var lot: Vector2i = plan_a.empty_lots[0]
	_apply_ok(errors, world, A, GameCommand.set_zone(lot.x, lot.y, SliceConstants.Zone.R), "zone an empty lot")
	_expect(errors, world.tile_at(lot.x, lot.y).power_covered and _has_road(world, lot.x, lot.y), "empty lot has road and power")
	world.sim_tick(21)
	world.sim_tick(22)
	_expect(errors, world.tile_at(lot.x, lot.y).building_tier == 1, "zoned empty lot grows to tier 1 in two ticks")
	# Save round trip right after seeding: the town comes back tile for tile.
	var seeded = _world()
	seeded.seed_starter_cities()
	var save: Dictionary = seeded.to_save_dict()
	var restored = WorldStateScript.from_save_dict(JSON.parse_string(JSON.stringify(save)))
	if restored == null:
		errors.append("starter save did not restore")
		return
	_expect(errors, restored.seed_starter_cities() == 0, "restored town is not seeded twice")
	_expect(errors, JSON.stringify(restored.to_save_dict()) == JSON.stringify(save), "restored starter town saves identically")
	for faction in [A, B]:
		var origin: Vector2i = WorldStateScript.starter_plan(faction).origin
		for y in WorldStateScript.SPAWN_SIZE:
			for x in WorldStateScript.SPAWN_SIZE:
				var before: TileDelta = seeded.tile_at(origin.x + x, origin.y + y)
				var after: TileDelta = restored.tile_at(origin.x + x, origin.y + y)
				if before.to_dict() != after.to_dict():
					errors.append("restored tile %s differs: %s vs %s" % [Vector2i(before.x, before.y), before.to_dict(), after.to_dict()])
		var plant: Vector2i = WorldStateScript.starter_plan(faction).plant
		_expect(errors, restored.has_power_source(plant.x, plant.y), "F%d restored plant" % faction)
	_expect(errors, restored.population(A) == seeded.population(A) and restored.jobs(A) == seeded.jobs(A), "restored counters match")
	seeded.sim_tick(1)
	seeded.sim_tick(2)
	restored.sim_tick(1)
	restored.sim_tick(2)
	_expect(errors, _tier_histogram(restored, WorldStateScript.SPAWN_A) == grown and _tier_histogram(seeded, WorldStateScript.SPAWN_A) == grown, "restored town grows like the original")
	_perf_note("starter town per block: %d edges, %d buildings (%d R / %d C / %d I), load %d at start and %d grown, capacity %d (storm %d); income %.3f/s at pace 1.0 once grown" % [
		plan_a.edges.size(), plan_a.building_count(), r_lots, c_lots, i_lots, plan_a.power_load(), _grown_load(plan_a), cap, int(floor(float(cap) * SliceConstants.CRISIS_CAPACITY_FACTOR)), income_grown,
	])


## The smoke's scenario b on faction B (claim the tile west of the spawn, zone it R,
## road it to the corner) must not unsettle B's town: after 20 ticks both blocks
## hold the same tiers, B has more population, and B's score leads. That is what
## run_smoke.sh step 6 (winner = builder) relies on.
func _check_starter_smoke_b(errors: Array[String]) -> void:
	var world = _world()
	world.seed_starter_cities()
	world.free_build = true
	var out: Vector2i = WorldStateScript.SPAWN_B + Vector2i(-1, 0)
	var inn: Vector2i = WorldStateScript.SPAWN_B
	_apply_ok(errors, world, B, GameCommand.claim_tile(out.x, out.y), "B claims the out tile")
	_apply_ok(errors, world, B, GameCommand.set_zone(out.x, out.y, SliceConstants.Zone.R), "B zones it R")
	_apply_ok(errors, world, B, GameCommand.add_edge(out, inn), "B roads it to the corner")
	_expect(errors, world.tile_at(out.x, out.y).power_covered, "the out tile is inside B's plant square")
	for tick in 20:
		world.sim_tick(tick + 1)
		_expect(errors, _brownout_count(world, WorldStateScript.SPAWN_B) == 0 and not world.tile_at(out.x, out.y).brownout, "tick %d no brownout on B" % (tick + 1))
	_expect(errors, _tier_histogram(world, WorldStateScript.SPAWN_A) == _tier_histogram(world, WorldStateScript.SPAWN_B), "both blocks hold the same tiers after the smoke's build (%s vs %s)" % [_tier_histogram(world, WorldStateScript.SPAWN_A), _tier_histogram(world, WorldStateScript.SPAWN_B)])
	_expect(errors, world.tile_at(out.x, out.y).building_tier >= 1, "the smoke's R tile grew")
	_expect(errors, world.population(B) > world.population(A), "B has more population (%d > %d)" % [world.population(B), world.population(A)])
	var score: ScoreTick = world.score(0)
	_expect(errors, score.factions[B].total() > score.factions[A].total(), "B leads the score (%.4f > %.4f)" % [score.factions[B].total(), score.factions[A].total()])


## 100 ticks at pace 0.01 on three maps: empty; a 64×64 city with every tile zoned
## and plants every six tiles (81 buildings in every plant's square: all dark, no
## growth, the pass still visits 4096 tiles); and a 64×64 city with one tile in
## five zoned and plants every four tiles (≈ 16 buildings per plant, at most 51
## load units fully grown: everything served, tiers keep moving every two ticks,
## pollution and congestion churn). The zone cycle 5 R / 2 C / 2 I keeps every
## demand gate open at any uniform tier and after R and C outgrow the factories,
## so the city only ever grows and the population check cannot land in a trough.
func _check_perf(errors: Array[String]) -> void:
	var empty = _world()
	var empty_avg := _time_ticks(empty, PERF_TICKS)

	var dark = _world()
	var dark_stats := _build_city(errors, dark, 1, 6)
	if dark_stats.is_empty():
		return
	var dark_avg := _time_ticks(dark, PERF_TICKS)
	_expect(errors, dark.population(A) == dark_stats["r_tiles"], "over-loaded city stays at tier 0 (population %d)" % dark.population(A))

	var live = _world()
	var live_stats := _build_city(errors, live, 5, 4)
	if live_stats.is_empty():
		return
	var live_avg := _time_ticks(live, PERF_TICKS)
	var pop: int = live.population(A)
	_expect(errors, pop > live_stats["r_tiles"], "served city grew (population %d from %d R tiles)" % [pop, live_stats["r_tiles"]])
	# The same served city at pace 1.0: timers accumulate but no tier moves inside
	# 100 ticks, which is the steady-state cost of a real round.
	var steady = _world(1.0)
	var steady_stats := _build_city(errors, steady, 5, 4)
	if steady_stats.is_empty():
		return
	var steady_avg := _time_ticks(steady, PERF_TICKS)
	_perf_line = "SIM_PERF ticks=%d empty_avg_ms=%.3f | dark pace=%.2f avg_ms=%.3f active=%d edges=%d plants=%d | churn pace=%.2f avg_ms=%.3f active=%d edges=%d plants=%d population=%d | steady pace=1.00 avg_ms=%.3f active=%d | setup_ms=%.0f" % [
		PERF_TICKS, empty_avg,
		TEST_PACE, dark_avg, dark_stats["active"], dark_stats["edges"], dark_stats["plants"],
		TEST_PACE, live_avg, live_stats["active"], live_stats["edges"], live_stats["plants"], pop,
		steady_avg, steady_stats["active"],
		live_stats["setup_ms"],
	]


## Faction A claims PERF_SIDE², zones every zone_stride-th tile (5 R, 2 C, 2 I in
## turn), lays a road along every row plus an avenue every four rows, and places a
## plant every plant_stride tiles starting POWER_RADIUS in, so every plant's square
## is complete. Returns counts, or {} when a command failed.
func _build_city(errors: Array[String], world, zone_stride: int, plant_stride: int) -> Dictionary:
	world.free_build = true
	var side := PERF_SIDE
	var start := Time.get_ticks_usec()
	for y in side:
		for x in side:
			if world.tile_at(x, y).owner != A:
				var result: Dictionary = world.apply(A, GameCommand.claim_tile(x, y))
				if result["reason"] != ReasonCode.Id.OK:
					errors.append("perf claim (%d,%d) reason %d" % [x, y, result["reason"]])
					return {}
	var zones: Array = [
		SliceConstants.Zone.R, SliceConstants.Zone.R, SliceConstants.Zone.R, SliceConstants.Zone.R, SliceConstants.Zone.R,
		SliceConstants.Zone.C, SliceConstants.Zone.C, SliceConstants.Zone.I, SliceConstants.Zone.I,
	]
	var active := 0
	var r_tiles := 0
	var index := 0
	for y in side:
		for x in side:
			if (x + y) % zone_stride != 0:
				continue
			var zone: int = zones[index % zones.size()]
			index += 1
			world.apply(A, GameCommand.set_zone(x, y, zone))
			active += 1
			if zone == SliceConstants.Zone.R:
				r_tiles += 1
	var edges := 0
	for y in side:
		for x in side:
			if x + 1 < side:
				world.apply(A, GameCommand.add_edge(Vector2i(x, y), Vector2i(x + 1, y)))
				edges += 1
			if y % 4 == 0 and y + 1 < side:
				world.apply(A, GameCommand.add_edge(Vector2i(x, y), Vector2i(x, y + 1)))
				edges += 1
	var plants := 0
	for y in range(SliceConstants.POWER_RADIUS, side, plant_stride):
		for x in range(SliceConstants.POWER_RADIUS, side, plant_stride):
			world.apply(A, GameCommand.place_power(x, y))
			plants += 1
	return {
		"active": active,
		"r_tiles": r_tiles,
		"edges": edges,
		"plants": plants,
		"setup_ms": float(Time.get_ticks_usec() - start) / 1000.0,
	}


# --- Builders --------------------------------------------------------------------


func _world(pace: float = TEST_PACE):
	var world = WorldStateScript.new()
	world.pace = pace
	return world


## R at (0,0) with a road to the C at (1,0) and a plant at (2,2) that covers both.
func _build_served_r(errors: Array[String], world) -> void:
	_apply_ok(errors, world, A, GameCommand.set_zone(0, 0, SliceConstants.Zone.R), "served R zone")
	_apply_ok(errors, world, A, GameCommand.set_zone(1, 0, SliceConstants.Zone.C), "served R jobs")
	_apply_ok(errors, world, A, GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 0)), "served R road")
	_apply_ok(errors, world, A, GameCommand.place_power(2, 2), "served R plant")
	_expect(errors, world.tile_at(0, 0).power_covered and not world.tile_at(0, 0).brownout, "served R has power")


## Ticks until the tile reaches the tier; 0 when it does not within the limit.
func _ticks_until(world, x: int, y: int, tier: int, limit: int) -> int:
	for i in limit:
		world.sim_tick(100 + i)
		if world.tile_at(x, y).building_tier == tier:
			return i + 1
	return 0


func _claim_line(errors: Array[String], world, faction: int, start: Vector2i, step: Vector2i, count: int) -> void:
	var cell := start
	for i in count:
		var result: Dictionary = world.apply(faction, GameCommand.claim_tile(cell.x, cell.y))
		if result["reason"] != ReasonCode.Id.OK:
			errors.append("claim chain %s reason %d" % [cell, result["reason"]])
			return
		cell += step


## Tiles of faction A's spawn inside the Chebyshev radius around center (the plant's
## coverage square), excluding the center itself, nearest first.
func _square_in_spawn(center: Vector2i, radius: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for d in range(1, radius + 1):
		for y in WorldStateScript.SPAWN_SIZE:
			for x in WorldStateScript.SPAWN_SIZE:
				if maxi(absi(x - center.x), absi(y - center.y)) == d:
					cells.append(Vector2i(x, y))
	return cells


func _has_road(world, x: int, y: int) -> bool:
	for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var other := Vector2i(x + step.x, y + step.y)
		if SliceConstants.in_map(other.x, other.y) and world.find_edge(Vector2i(x, y), other) != null:
			return true
	return false


## Building tiers of one spawn block as [tier0, tier1, tier2] counts.
func _tier_histogram(world, origin: Vector2i) -> Array:
	var hist := [0, 0, 0]
	for y in WorldStateScript.SPAWN_SIZE:
		for x in WorldStateScript.SPAWN_SIZE:
			var tile: TileDelta = world.tile_at(origin.x + x, origin.y + y)
			if tile.has_building:
				hist[tile.building_tier] += 1
	return hist


func _brownout_count(world, origin: Vector2i) -> int:
	var count := 0
	for y in WorldStateScript.SPAWN_SIZE:
		for x in WorldStateScript.SPAWN_SIZE:
			if world.tile_at(origin.x + x, origin.y + y).brownout:
				count += 1
	return count


## Σ (tier + 1) of the plan once every R and C lot stands at BUILDING_TIER_MAX and
## the factories stay where they start.
func _grown_load(plan) -> int:
	var total := 0
	for lot in plan.lots:
		if int(lot[1]) == SliceConstants.Zone.I:
			total += int(lot[2]) + 1
		else:
			total += SliceConstants.BUILDING_TIER_MAX + 1
	return total


func _time_ticks(world, ticks: int) -> float:
	var start := Time.get_ticks_usec()
	for i in ticks:
		world.sim_tick(i + 1)
	return float(Time.get_ticks_usec() - start) / 1000.0 / float(ticks)


# --- Assertions ----------------------------------------------------------------


func _apply_ok(errors: Array[String], world, faction: int, cmd: GameCommand, label: String) -> Dictionary:
	var result: Dictionary = world.apply(faction, cmd)
	if result["reason"] != ReasonCode.Id.OK:
		errors.append("setup %s rejected reason=%d detail=%s" % [label, result["reason"], result["detail"]])
	return result


func _tile_delta_for(events: Array, x: int, y: int) -> ServerEvent:
	for event in events:
		if event.kind == ServerEvent.Kind.TILE_DELTA and event.tile_delta.x == x and event.tile_delta.y == y:
			return event
	return null


func _has_kind(events: Array, kind: int) -> bool:
	return _first_kind(events, kind) != null


func _count_kind(events: Array, kind: int) -> int:
	var count := 0
	for event in events:
		if event.kind == kind:
			count += 1
	return count


func _first_kind(events: Array, kind: int) -> ServerEvent:
	for event in events:
		if event.kind == kind:
			return event
	return null


func _perf_note(text: String) -> void:
	print("SIM_NOTE %s" % text)


func _expect(errors: Array[String], cond: bool, message: String) -> void:
	if not cond:
		errors.append(message)

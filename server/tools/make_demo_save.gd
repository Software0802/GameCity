extends SceneTree

## Writes a save of two developed cities for demos and look-development.
##   godot --headless --path . -s res://server/tools/make_demo_save.gd -- [--out <path>] [--install <save-dir>] [--pace <float>]
##
##   --out <path>        where the envelope goes (user://saves/demo-city.json). user://,
##                       absolute, or cwd-relative, as ServerPersistence.resolve_path reads it.
##   --install <dir>     also write it as <dir>/world-<now>.json, the name the server's
##                       load_latest() picks up (for example .demo/save). Nothing is pruned.
##   --pace <float>      WorldState.pace stored in the save (1.0); --pace at server start
##                       overrides it anyway.
##
## Each faction owns a CITY_SIDE² corner of the map. The inner 2×2 spawn-sized blocks
## carry the starter layout (server/sim/starter_city.gd) in four reflections, each
## plant on the map-corner side of its block so no square reaches into a neighbour,
## joined by connector roads at the cross junctions. The three blocks nearest the
## map corner are fully grown (every lot at tier 2, factories included), the far
## block is young (everything at tier 1), and every block's spare lots are freshly
## zoned at tier 0. The outer strip stays claimed and bare. The city therefore grows
## on a live server instead of decaying: every lot keeps the starter spacing (edges
## far under the congestion knee, smoke out of reach of R and C), each plant carries
## at most 51 of its POWER_PLANT_CAPACITY, and the R / C / I mix keeps the demand
## triangle open at every tier.
##
## The envelope is ServerPersistence.build_envelope() with an empty player table and a
## round that starts now and runs ROUND_SECONDS_DEFAULT, so a server started on it
## sees a live round for seven days after generation. After writing, the file is read
## back through ServerPersistence.parse_envelope and ticked once; the tool prints
## DEMO_SAVE_OK pop=<n> tiles=<n> ... and exits 0, or DEMO_SAVE_FAIL and exits 1.

const StarterCity = preload("res://server/sim/starter_city.gd")

const DEFAULT_OUT := "user://saves/demo-city.json"
## Claimed square per faction, from its map corner.
const CITY_SIDE := 20
## Spawn-sized blocks per axis that get the starter layout.
const CITY_BLOCKS := 2
## Zones for a block's spare lots, in StarterCity.Plan.empty_lots order.
const SPARE_ZONES: Array[int] = [SliceConstants.Zone.R, SliceConstants.Zone.C, SliceConstants.Zone.R]
const A := SliceConstants.Owner.FACTION_A
const B := SliceConstants.Owner.FACTION_B
const EXIT_BAD_ARGS := 2


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_arg := DEFAULT_OUT
	var install_dir := ""
	var pace := SliceConstants.PACE_DEFAULT
	var i := 0
	while i < args.size():
		var flag := args[i]
		var value := args[i + 1] if i + 1 < args.size() else ""
		match flag:
			"--out":
				out_arg = value
				i += 2
			"--install":
				install_dir = value
				i += 2
			"--pace":
				if value.is_valid_float() and float(value) > 0.0:
					pace = float(value)
				else:
					_fail("--pace must be a positive number, got %s" % value, EXIT_BAD_ARGS)
					return
				i += 2
			_:
				_fail("unknown argument %s" % flag, EXIT_BAD_ARGS)
				return
	if out_arg.is_empty():
		_fail("--out needs a path", EXIT_BAD_ARGS)
		return

	var world := WorldState.new()
	world.pace = pace
	var stats := _build(world)
	if stats.has("error"):
		_fail(str(stats["error"]), 1)
		return
	# One tick fills satisfaction, pollution, and congestion so the first snapshot
	# already shows lit windows; the tier timers move by one sim second.
	world.sim_tick(1)
	var problems := _audit(world, "built")
	if not problems.is_empty():
		_fail("built world: " + "; ".join(problems), 1)
		return

	var now := int(floor(Time.get_unix_time_from_system()))
	var round_state := ServerPersistence.RoundState.new()
	round_state.started_at_unix = now
	round_state.ends_at_unix = now + SliceConstants.ROUND_SECONDS_DEFAULT
	round_state.pace = pace
	round_state.phase = ServerPersistence.PHASE_PLAY
	round_state.crisis_fired = false
	round_state.tick = 1
	var envelope := ServerPersistence.build_envelope(world, Players.new(), round_state, now)

	var out_path := ServerPersistence.resolve_path(out_arg)
	var written := _write(out_path, envelope)
	if written != OK:
		_fail("write %s: %s" % [out_path, error_string(written)], 1)
		return
	var installed := ""
	if not install_dir.is_empty():
		var dir := ServerPersistence.resolve_path(install_dir)
		installed = dir.path_join(ServerPersistence.file_name_for(now * 1000))
		var err := _write(installed, envelope)
		if err != OK:
			_fail("install %s: %s" % [installed, error_string(err)], 1)
			return

	# Read back the way the server does, then tick once more.
	var loaded := ServerPersistence.parse_envelope(ServerPersistence.read_json(out_path), out_path)
	if loaded == null:
		_fail("%s did not parse as a save envelope" % out_path, 1)
		return
	loaded.world.pace = pace
	loaded.world.sim_tick(2)
	problems = _audit(loaded.world, "reloaded")
	var pop: int = loaded.world.population(A) + loaded.world.population(B)
	if pop <= 0:
		problems.append("population %d after reload" % pop)
	if not problems.is_empty():
		_fail("reloaded world: " + "; ".join(problems), 1)
		return

	for faction in [A, B]:
		print(_city_map(loaded.world, faction))
		var state: FactionState = loaded.world.faction_states()[faction]
		print("faction %d: owned=%d buildings=%d plants=%d pop=%d jobs=%d income=%.3f/s power=%d/%d demand R %.2f C %.2f I %.2f" % [
			faction, loaded.world.owned_count(faction), stats["buildings"][faction], stats["plants"][faction],
			state.population, state.jobs, state.income_per_sec, state.power_load, state.power_capacity,
			state.demand_r, state.demand_c, state.demand_i,
		])
	var world_dict: Dictionary = envelope["world"]
	print("DEMO_SAVE_OK pop=%d tiles=%d buildings=%d edges=%d plants=%d tiers=%s path=%s%s" % [
		pop, world_dict["tiles"].size(), int(stats["buildings"][A]) + int(stats["buildings"][B]),
		world_dict["edges"].size(), world_dict["power_sources"].size(), str(stats["tiers"]), out_path,
		"" if installed.is_empty() else " installed=" + installed,
	])
	quit(0)


# ---------------------------------------------------------------- build


## Claims each faction's corner and seeds the blocks. Returns the counts, or
## {"error": ...} when a command or plan was refused.
func _build(world: WorldState) -> Dictionary:
	var stats := {"buildings": {A: 0, B: 0}, "plants": {A: 0, B: 0}, "tiers": [0, 0, 0]}
	world.free_build = true
	for faction in [A, B]:
		var step := Vector2i(1, 1) if faction == A else Vector2i(-1, -1)
		var corner := Vector2i(0, 0) if faction == A else Vector2i(SliceConstants.MAP_SIZE - 1, SliceConstants.MAP_SIZE - 1)
		# Row-major from the corner: every tile touches one claimed just before it.
		for dy in CITY_SIDE:
			for dx in CITY_SIDE:
				var cell := corner + Vector2i(dx * step.x, dy * step.y)
				if world.tile_at(cell.x, cell.y).owner == faction:
					continue
				var result: Dictionary = world.apply(faction, GameCommand.claim_tile(cell.x, cell.y))
				if result["reason"] != ReasonCode.Id.OK:
					return {"error": "faction %d claim %s rejected %d" % [faction, cell, result["reason"]]}
		var spawn: Vector2i = WorldState.SPAWN_A if faction == A else WorldState.SPAWN_B
		var block := WorldState.SPAWN_SIZE
		for by in CITY_BLOCKS:
			for bx in CITY_BLOCKS:
				# Block (0,0) is the spawn block itself; the others step away from the corner.
				# A plan's origin is always the block's top-left tile.
				var origin := spawn + Vector2i(bx * block * step.x, by * block * step.y)
				var flip_x := _flipped(faction, bx)
				var flip_y := _flipped(faction, by)
				var plan := StarterCity.mirrored(StarterCity.plan_for(origin), flip_x, flip_y)
				var grown := bx + by <= 1
				_develop(plan, grown)
				if not world.seed_plan(faction, plan):
					return {"error": "faction %d block %s refused" % [faction, origin]}
				stats["plants"][faction] += 1
				stats["buildings"][faction] += plan.lots.size()
				for lot in plan.lots:
					stats["tiers"][int(lot[2])] += 1
		# Connector roads between neighbouring blocks at their cross junctions. Blocks
		# in one row share flip_y (one column: flip_x), so both junctions line up.
		for by in CITY_BLOCKS:
			for bx in CITY_BLOCKS:
				var origin := spawn + Vector2i(bx * block * step.x, by * block * step.y)
				var cross_x := _cross_index(_flipped(faction, bx))
				var cross_y := _cross_index(_flipped(faction, by))
				var far_x := origin.x + block - 1 if step.x > 0 else origin.x
				var far_y := origin.y + block - 1 if step.y > 0 else origin.y
				if bx + 1 < CITY_BLOCKS:
					var a := Vector2i(far_x, origin.y + cross_y)
					var result: Dictionary = world.apply(faction, GameCommand.add_edge(a, a + Vector2i(step.x, 0)))
					if result["reason"] != ReasonCode.Id.OK:
						return {"error": "faction %d connector at %s rejected %d" % [faction, a, result["reason"]]}
				if by + 1 < CITY_BLOCKS:
					var a := Vector2i(origin.x + cross_x, far_y)
					var result: Dictionary = world.apply(faction, GameCommand.add_edge(a, a + Vector2i(0, step.y)))
					if result["reason"] != ReasonCode.Id.OK:
						return {"error": "faction %d connector at %s rejected %d" % [faction, a, result["reason"]]}
	world.free_build = false
	return stats


## A's blocks are reflected when they step away from the map corner, B's when they
## do not: the plant then sits on the corner side of every block and no square
## reaches into a neighbouring block.
static func _flipped(faction: int, block_index: int) -> bool:
	return (block_index == 1) != (faction == B)


## Block-relative index of a cross street after an optional reflection.
static func _cross_index(flipped: bool) -> int:
	return StarterCity.BLOCK - 1 - StarterCity.CROSS if flipped else StarterCity.CROSS


## Grown blocks: every lot at BUILDING_TIER_MAX. Young blocks keep the starter tier.
## Spare lots join at tier 0 with SPARE_ZONES.
static func _develop(plan: StarterCity.Plan, grown: bool) -> void:
	if grown:
		for lot in plan.lots:
			lot[2] = SliceConstants.BUILDING_TIER_MAX
	var index := 0
	for cell in plan.empty_lots:
		plan.lots.append([cell, SPARE_ZONES[index % SPARE_ZONES.size()], SliceConstants.BUILDING_TIER_MIN])
		index += 1
	plan.empty_lots = []


# ---------------------------------------------------------------- audit and output


## Problems a demo save must not have: brownout anywhere, an unpowered or roadless
## building, a closed demand gate, no population.
func _audit(world: WorldState, label: String) -> Array[String]:
	var problems: Array[String] = []
	var brownout := 0
	var unpowered := 0
	var roadless := 0
	for y in SliceConstants.MAP_SIZE:
		for x in SliceConstants.MAP_SIZE:
			var tile := world.tile_at(x, y)
			if tile.brownout:
				brownout += 1
			if tile.has_building:
				if not tile.power_covered:
					unpowered += 1
				if not _has_road(world, x, y):
					roadless += 1
	if brownout > 0:
		problems.append("%s: %d tiles in brownout" % [label, brownout])
	if unpowered > 0:
		problems.append("%s: %d buildings without power" % [label, unpowered])
	if roadless > 0:
		problems.append("%s: %d buildings without a road" % [label, roadless])
	for faction in [A, B]:
		var state: FactionState = world.faction_states()[faction]
		if state.population <= 0:
			problems.append("%s: faction %d has no population" % [label, faction])
		if state.demand_r <= 0.0 or state.demand_c <= 0.0 or state.demand_i <= 0.0:
			problems.append("%s: faction %d demand gate closed (R %.2f C %.2f I %.2f)" % [label, faction, state.demand_r, state.demand_c, state.demand_i])
	return problems


static func _has_road(world: WorldState, x: int, y: int) -> bool:
	for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var other := Vector2i(x + step.x, y + step.y)
		if SliceConstants.in_map(other.x, other.y) and world.find_edge(Vector2i(x, y), other) != null:
			return true
	return false


## The faction's CITY_SIDE² corner as text: P plant, # road tile, r/c/i tier 0,
## R/C/I tier 1, H/T/F tier 2 (high-rise, tower, factory), . bare owned land.
func _city_map(world: WorldState, faction: int) -> String:
	var corner := Vector2i(0, 0) if faction == A else Vector2i(SliceConstants.MAP_SIZE - CITY_SIDE, SliceConstants.MAP_SIZE - CITY_SIDE)
	var lines: PackedStringArray = PackedStringArray()
	lines.append("faction %d city at %s (x right, y down):" % [faction, corner])
	for dy in CITY_SIDE:
		var row := ""
		for dx in CITY_SIDE:
			var x := corner.x + dx
			var y := corner.y + dy
			var tile := world.tile_at(x, y)
			var glyph := "."
			if world.has_power_source(x, y):
				glyph = "P"
			elif tile.has_building:
				var letters := ["", "rRH", "cCT", "iIF"]
				glyph = letters[tile.zone][tile.building_tier]
			elif _has_road(world, x, y):
				glyph = "#"
			row += glyph + " "
		lines.append(row.strip_edges(false, true))
	return "\n".join(lines)


func _write(path: String, envelope: Dictionary) -> Error:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK:
			return err
	return ServerPersistence.write_json_atomic(path, envelope)


func _fail(message: String, code: int) -> void:
	print("DEMO_SAVE_FAIL %s" % message)
	quit(code)

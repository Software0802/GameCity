extends SceneTree

## Headless save round-trip check. No second peer.
##   godot --headless --path . -s res://server/save_roundtrip_check.gd
## Builds a world, applies commands for both factions, runs sim ticks so power,
## congestion, and the crisis latch are really written, then
## to_save_dict → JSON.stringify → JSON.parse_string → from_save_dict and compares
## every tile, edge, power source, and crisis flag. Prints SAVE_OK and exits 0,
## or prints each difference and exits 1.

const WorldStateScript = preload("res://server/world_state.gd")
const MAX_DIFFS_PRINTED := 20


func _initialize() -> void:
	var errors: Array[String] = []
	_check_populated_roundtrip(errors)
	_check_fresh_world_roundtrip(errors)
	_check_map_size_guard(errors)
	if errors.is_empty():
		print("SAVE_OK")
		quit(0)
	else:
		var shown := 0
		for err in errors:
			if shown >= MAX_DIFFS_PRINTED:
				print("SAVE_FAIL ... %d more" % (errors.size() - shown))
				break
			print("SAVE_FAIL %s" % err)
			shown += 1
		quit(1)


func _check_populated_roundtrip(errors: Array[String]) -> void:
	var world = WorldStateScript.new()
	var a := SliceConstants.Owner.FACTION_A
	var b := SliceConstants.Owner.FACTION_B
	var spawn_b: Vector2i = WorldStateScript.SPAWN_B

	# Faction A: claims, every zone, an edge pair, a plant, a demolished tile.
	_apply_ok(errors, world, a, GameCommand.claim_tile(8, 0), "A claim 8,0")
	_apply_ok(errors, world, a, GameCommand.claim_tile(9, 0), "A claim 9,0")
	_apply_ok(errors, world, a, GameCommand.set_zone(0, 0, SliceConstants.Zone.R), "A zone R")
	_apply_ok(errors, world, a, GameCommand.set_zone(1, 0, SliceConstants.Zone.C), "A zone C")
	_apply_ok(errors, world, a, GameCommand.set_zone(8, 0, SliceConstants.Zone.I), "A zone I")
	_apply_ok(errors, world, a, GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 0)), "A edge x")
	_apply_ok(errors, world, a, GameCommand.add_edge(Vector2i(0, 0), Vector2i(0, 1)), "A edge y")
	_apply_ok(errors, world, a, GameCommand.place_power(2, 2), "A power")
	_apply_ok(errors, world, a, GameCommand.set_zone(3, 0, SliceConstants.Zone.C), "A zone C 3,0")
	_apply_ok(errors, world, a, GameCommand.demolish_own(3, 0), "A demolish 3,0")

	# Faction B: mirrored corner, derived from SPAWN_B.
	var claim_b := spawn_b + Vector2i(-1, 0)
	_apply_ok(errors, world, b, GameCommand.claim_tile(claim_b.x, claim_b.y), "B claim")
	_apply_ok(errors, world, b, GameCommand.set_zone(spawn_b.x, spawn_b.y, SliceConstants.Zone.R), "B zone R")
	_apply_ok(errors, world, b, GameCommand.add_edge(spawn_b, spawn_b + Vector2i(1, 0)), "B edge")
	var plant_b := spawn_b + Vector2i(3, 3)
	_apply_ok(errors, world, b, GameCommand.place_power(plant_b.x, plant_b.y), "B power")

	# Fields the wave 0 sim does not write yet still have to survive the save.
	var poked: TileDelta = world.tile_at(3, 3)
	poked.satisfaction = 0.625
	poked.pollution = 0.125
	poked.brownout = true
	poked.building_tier = 2

	# Ticks write power_covered / congestion, then the crisis latch.
	world.sim_tick(1)
	var crisis_events: Array = world.sim_tick(WorldStateScript.CRISIS_TICK)
	_expect(errors, _has_kind(crisis_events, ServerEvent.Kind.CRISIS_EVENT), "crisis fired before save")
	_expect(errors, world.crisis_active and world._crisis_sent, "crisis flags set before save")
	_expect(errors, world.tile_at(0, 4).power_covered, "power covered before save")

	var save: Dictionary = world.to_save_dict()
	_check_save_shape(errors, world, save)

	var text := JSON.stringify(save)
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		errors.append("JSON.parse_string did not return a Dictionary")
		return
	var restored = WorldStateScript.from_save_dict(parsed)
	if restored == null:
		errors.append("from_save_dict returned null for a valid save")
		return

	_compare_worlds(errors, world, restored, "populated")

	# The latch survives: a restored world does not fire the crisis again.
	var after: Array = restored.sim_tick(WorldStateScript.CRISIS_TICK + 1)
	_expect(errors, not _has_kind(after, ServerEvent.Kind.CRISIS_EVENT), "restored world does not refire crisis")
	# And the restored world keeps simulating from the same state.
	var score: ServerEvent = _first_kind(after, ServerEvent.Kind.SCORE_TICK)
	_expect(errors, score != null and score.score_tick.factions.size() == 2, "restored world scores")

	# Saving the restored world reproduces the same JSON text.
	var again := JSON.stringify(restored.to_save_dict())
	_expect(errors, again == text, "second save text equals first")


func _check_fresh_world_roundtrip(errors: Array[String]) -> void:
	var world = WorldStateScript.new()
	var save: Dictionary = world.to_save_dict()
	var expected_spawn := WorldStateScript.SPAWN_SIZE * WorldStateScript.SPAWN_SIZE * 2
	_expect(errors, save["tiles"].size() == expected_spawn, "fresh save holds only the %d spawn tiles (got %d)" % [expected_spawn, save["tiles"].size()])
	_expect(errors, save["edges"].is_empty() and save["power_sources"].is_empty(), "fresh save has no edges or plants")
	_expect(errors, save["crisis_active"] == false and save["crisis_sent"] == false, "fresh save crisis flags false")
	var parsed = JSON.parse_string(JSON.stringify(save))
	var restored = WorldStateScript.from_save_dict(parsed)
	if restored == null:
		errors.append("from_save_dict returned null for a fresh save")
		return
	_compare_worlds(errors, world, restored, "fresh")
	_expect(errors, restored.tile_at(0, 0).owner == SliceConstants.Owner.FACTION_A, "fresh restore keeps spawn A")
	var spawn_b: Vector2i = WorldStateScript.SPAWN_B
	_expect(errors, restored.tile_at(spawn_b.x, spawn_b.y).owner == SliceConstants.Owner.FACTION_B, "fresh restore keeps spawn B")


func _check_map_size_guard(errors: Array[String]) -> void:
	print("(expected: one push_error about map_size follows)")
	var wrong = WorldStateScript.from_save_dict({"map_size": SliceConstants.MAP_SIZE / 2})
	_expect(errors, wrong == null, "from_save_dict rejects a different map_size")


func _check_save_shape(errors: Array[String], world, save: Dictionary) -> void:
	for key in ["map_size", "tiles", "edges", "power_sources", "crisis_active", "crisis_sent"]:
		_expect(errors, save.has(key), "save has key %s" % key)
	_expect(errors, save.get("map_size") == SliceConstants.MAP_SIZE, "save map_size")
	# Only non-default tiles are stored. Count them independently, field by field.
	var non_default := 0
	for y in SliceConstants.MAP_SIZE:
		for x in SliceConstants.MAP_SIZE:
			var actual: Dictionary = world.tile_at(x, y).to_dict()
			var blank: Dictionary = TileDelta.from_cell(x, y).to_dict()
			if not _values_equal(actual, blank, true):
				non_default += 1
	var tiles: Array = save["tiles"]
	_expect(errors, tiles.size() == non_default, "save stores %d non-default tiles (got %d)" % [non_default, tiles.size()])
	_expect(errors, non_default < SliceConstants.MAP_SIZE * SliceConstants.MAP_SIZE, "save omits default tiles")
	var last_id := -1
	for raw in tiles:
		var id := int(raw.get("id", -1))
		_expect(errors, id > last_id, "tiles ascending by id at %d" % id)
		last_id = id
	_expect(errors, save["edges"].size() == 3, "save stores 3 edges (got %d)" % save["edges"].size())
	_expect(errors, save["power_sources"].size() == 2, "save stores 2 plants (got %d)" % save["power_sources"].size())
	_expect(errors, save["crisis_active"] == true and save["crisis_sent"] == true, "save crisis flags true")


func _compare_worlds(errors: Array[String], original, restored, label: String) -> void:
	for y in SliceConstants.MAP_SIZE:
		for x in SliceConstants.MAP_SIZE:
			var want: Dictionary = original.tile_at(x, y).to_dict()
			var got: Dictionary = restored.tile_at(x, y).to_dict()
			for key in want:
				if not _values_equal(want[key], got.get(key), true):
					errors.append("%s tile (%d,%d) %s: %s != %s" % [label, x, y, key, want[key], got.get(key)])
	var want_edges: Dictionary = original._edges
	var got_edges: Dictionary = restored._edges
	for key in want_edges:
		if not got_edges.has(key):
			errors.append("%s edge %s missing after restore" % [label, key])
			continue
		var want_edge: Dictionary = want_edges[key].to_dict()
		var got_edge: Dictionary = got_edges[key].to_dict()
		if not _values_equal(want_edge, got_edge, true):
			errors.append("%s edge %s: %s != %s" % [label, key, want_edge, got_edge])
	for key in got_edges:
		if not want_edges.has(key):
			errors.append("%s edge %s appeared after restore" % [label, key])
	var want_sources: Array = original._power_sources.keys()
	var got_sources: Array = restored._power_sources.keys()
	want_sources.sort()
	got_sources.sort()
	if not _values_equal(want_sources, got_sources, true):
		errors.append("%s power sources %s != %s" % [label, want_sources, got_sources])
	_expect(errors, original.crisis_active == restored.crisis_active, "%s crisis_active restored" % label)
	_expect(errors, original._crisis_sent == restored._crisis_sent, "%s crisis_sent restored" % label)
	_expect(errors, _values_equal(original.to_save_dict(), restored.to_save_dict(), true), "%s to_save_dict identical after restore" % label)


## Deep compare. Numbers compare by value with is_equal_approx; with strict_types an
## int and a float never match, which catches a from_dict that forgot to cast.
static func _values_equal(a, b, strict_types: bool) -> bool:
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not _values_equal(a[key], b[key], strict_types):
				return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _values_equal(a[i], b[i], strict_types):
				return false
		return true
	var a_num := a is int or a is float
	var b_num := b is int or b is float
	if a_num and b_num:
		if strict_types and typeof(a) != typeof(b):
			return false
		return is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b


func _apply_ok(errors: Array[String], world, faction: int, cmd: GameCommand, label: String) -> void:
	var result: Dictionary = world.apply(faction, cmd)
	if result["reason"] != ReasonCode.Id.OK:
		errors.append("setup %s rejected reason=%d detail=%s" % [label, result["reason"], result["detail"]])


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

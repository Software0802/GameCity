extends SceneTree

## Headless persistence + player table check. No second peer, no network.
##   godot --headless --path . -s res://server/persistence_check.gd
## Covers: Players faction balance and token lookup; RoundState validation; the
## save envelope written by ServerPersistence into a scratch directory under
## user://, read back and compared field by field; rotation to KEEP_LATEST; a
## corrupt newest file being skipped; a version mismatch being refused; and the
## --new-round backup move. Prints PERSIST_OK and exits 0, or each difference
## and exits 1. One push_error about the version mismatch is expected output.

const WorldStateScript = preload("res://server/world_state.gd")
const PlayersScript = preload("res://server/players.gd")
const PersistenceScript = preload("res://server/persistence.gd")
## Each check function bumps this when it runs to its end, so a runtime error that
## aborts a check mid-way cannot pass as OK.
const CHECK_COUNT := 4

var _completed := 0


func _initialize() -> void:
	var errors: Array[String] = []
	var scratch := "user://persistence_check/%d" % OS.get_process_id()
	_check_players(errors)
	_check_round_state(errors)
	_check_paths(errors)
	_check_envelope_roundtrip(errors, scratch)
	_cleanup(scratch)
	if _completed != CHECK_COUNT:
		errors.append("only %d of %d checks ran to completion (see SCRIPT ERROR above)" % [_completed, CHECK_COUNT])
	if errors.is_empty():
		print("PERSIST_OK")
		quit(0)
	else:
		for err in errors:
			print("PERSIST_FAIL %s" % err)
		quit(1)


func _check_players(errors: Array[String]) -> void:
	var table = PlayersScript.new()
	var a := SliceConstants.Owner.FACTION_A
	var b := SliceConstants.Owner.FACTION_B
	_expect(errors, table.pick_faction() == a, "empty table picks A")
	var token_alice: String = PlayersScript.new_token()
	var token_bob: String = PlayersScript.new_token()
	_expect(errors, token_alice.length() == 64 and token_alice != token_bob, "tokens are 64 hex and distinct")
	var alice = table.create("alice", table.pick_faction(), PlayersScript.hash_token(token_alice), 100)
	_expect(errors, alice.player_id == 1 and alice.faction == a, "first player is id 1 faction A")
	var bob = table.create("bob", table.pick_faction(), PlayersScript.hash_token(token_bob), 101)
	_expect(errors, bob.player_id == 2 and bob.faction == b, "second player balances to B")
	_expect(errors, table.pick_faction() == a, "tie picks A")
	table.create("carol", table.pick_faction(), PlayersScript.hash_token(PlayersScript.new_token()), 102)
	_expect(errors, table.pick_faction() == b, "2 vs 1 picks B")
	_expect(errors, table.find_by_token_hash(PlayersScript.hash_token(token_bob)) == bob, "lookup by token hash")
	_expect(errors, table.find_by_token_hash(PlayersScript.hash_token("nope")) == null, "unknown token hash")
	var scripted = table.create("smoke-host", a, "", 103)
	_expect(errors, table.find_by_token_hash("") == null, "empty hash never matches a scripted row")
	_expect(errors, scripted.player_id == 4, "ids keep counting")
	table.touch(bob.player_id, 555)
	_expect(errors, bob.last_seen_unix == 555, "touch updates last_seen")
	var rows: Array = table.to_save_array()
	_expect(errors, rows.size() == 4 and rows[1]["name"] == "bob" and rows[1]["last_seen_unix"] == 555, "to_save_array rows")
	for row in rows:
		_expect(errors, row.has("player_id") and row.has("token_sha256") and row.has("name") and row.has("faction") and row.has("last_seen_unix"), "row keys")
	var parsed = JSON.parse_string(JSON.stringify(rows, "", true, true))
	var back = PlayersScript.from_save_array(parsed)
	_expect(errors, back.size() == 4 and _values_equal(back.to_save_array(), rows), "players JSON roundtrip")
	_expect(errors, back.find_by_token_hash(PlayersScript.hash_token(token_bob)).faction == b, "restored bob keeps faction B")
	_expect(errors, back.create("erin", back.pick_faction(), "h", 1).player_id == 5, "restored table continues ids")
	var dirty: Array = [
		{"player_id": 7, "token_sha256": "x", "name": "ok", "faction": a, "last_seen_unix": 1},
		{"player_id": 7, "token_sha256": "y", "name": "dup", "faction": b, "last_seen_unix": 1},
		{"player_id": 0, "token_sha256": "z", "name": "bad id", "faction": a, "last_seen_unix": 1},
		{"player_id": 8, "token_sha256": "w", "name": "neutral", "faction": SliceConstants.Owner.NEUTRAL, "last_seen_unix": 1},
		"not a row",
	]
	print("(expected: four push_warning lines about skipped player rows follow)")
	var filtered = PlayersScript.from_save_array(dirty)
	_expect(errors, filtered.size() == 1 and filtered.find_by_id(7).name == "ok", "bad rows skipped, first wins")
	_completed += 1


func _check_round_state(errors: Array[String]) -> void:
	var round_state = PersistenceScript.RoundState.new()
	round_state.started_at_unix = 1000
	round_state.ends_at_unix = 1000 + 20
	round_state.pace = 0.5
	round_state.phase = PersistenceScript.PHASE_ENDED
	round_state.crisis_fired = true
	round_state.tick = 17
	var back = PersistenceScript.RoundState.from_dict(JSON.parse_string(JSON.stringify(round_state.to_dict(), "", true, true)))
	_expect(errors, back != null and _values_equal(back.to_dict(), round_state.to_dict()), "round roundtrip")
	_expect(errors, back != null and back.round_seconds() == 20 and back.is_ended(), "round helpers")
	_expect(errors, PersistenceScript.RoundState.from_dict({}) == null, "empty round rejected")
	_expect(errors, PersistenceScript.RoundState.from_dict({"started_at_unix": 5, "ends_at_unix": 5}) == null, "zero-length round rejected")
	_expect(errors, PersistenceScript.RoundState.from_dict({"started_at_unix": 5, "ends_at_unix": 9, "pace": 0.0}) == null, "zero pace rejected")
	_expect(errors, PersistenceScript.RoundState.from_dict({"started_at_unix": 5, "ends_at_unix": 9, "phase": "lobby"}) == null, "unknown phase rejected")
	var minimal = PersistenceScript.RoundState.from_dict({"started_at_unix": 5, "ends_at_unix": 9})
	_expect(errors, minimal != null and minimal.phase == PersistenceScript.PHASE_PLAY and minimal.tick == 0 and not minimal.crisis_fired, "round defaults")
	_completed += 1


func _check_paths(errors: Array[String]) -> void:
	var rel: String = PersistenceScript.resolve_path("rel/x")
	_expect(errors, rel.is_absolute_path() and rel.ends_with("/rel/x"), "relative path resolves against cwd (%s)" % rel)
	var user_path: String = PersistenceScript.resolve_path("user://saves")
	_expect(errors, user_path.is_absolute_path() and user_path.ends_with("/saves"), "user:// path resolves (%s)" % user_path)
	_expect(errors, PersistenceScript.resolve_path("/abs/here") == "/abs/here", "absolute path unchanged")
	_expect(errors, PersistenceScript.resolve_path("") == "", "empty path stays empty")
	var name: String = PersistenceScript.file_name_for(1791392014165)
	_expect(errors, name == "world-20261007T165334.165Z.json", "file name format (%s)" % name)
	_expect(errors, PersistenceScript.file_name_for(1791392014165) < PersistenceScript.file_name_for(1791392014166), "file names sort by time")
	_completed += 1


func _check_envelope_roundtrip(errors: Array[String], scratch: String) -> void:
	var store = PersistenceScript.new(scratch)
	_expect(errors, store.ensure_dir() == OK, "scratch dir created")
	_expect(errors, store.load_latest() == null, "no saves yet")

	var world = WorldStateScript.new()
	var a := SliceConstants.Owner.FACTION_A
	var spawn_b: Vector2i = WorldStateScript.SPAWN_B
	_apply_ok(errors, world, a, GameCommand.claim_tile(8, 0), "claim")
	_apply_ok(errors, world, a, GameCommand.set_zone(0, 0, SliceConstants.Zone.R), "zone")
	_apply_ok(errors, world, a, GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 0)), "edge")
	_apply_ok(errors, world, SliceConstants.Owner.FACTION_B, GameCommand.place_power(spawn_b.x, spawn_b.y), "power")
	world.sim_tick(1)
	var players = PlayersScript.new()
	players.create("alice", players.pick_faction(), PlayersScript.hash_token("t1"), 10)
	players.create("bob", players.pick_faction(), PlayersScript.hash_token("t2"), 11)
	var round_state = PersistenceScript.RoundState.new()
	round_state.started_at_unix = 2000
	round_state.ends_at_unix = 2000 + SliceConstants.ROUND_SECONDS_TEST
	round_state.pace = 0.01
	round_state.crisis_fired = true
	round_state.tick = 42

	var envelope: Dictionary = PersistenceScript.build_envelope(world, players, round_state, 2042)
	for key in ["version", "saved_at_unix", "round", "players", "world"]:
		_expect(errors, envelope.has(key), "envelope has %s" % key)
	_expect(errors, envelope["version"] == SliceConstants.SAVE_FORMAT_VERSION, "envelope version")
	_expect(errors, envelope["world"]["map_size"] == SliceConstants.MAP_SIZE, "envelope world map_size")

	var path: String = store.write(envelope)
	_expect(errors, path != "" and FileAccess.file_exists(path), "write produced a file")
	_expect(errors, path.get_file().begins_with(PersistenceScript.FILE_PREFIX) and path.get_file().ends_with(PersistenceScript.FILE_SUFFIX), "file name prefix/suffix")
	_expect(errors, not FileAccess.file_exists(path + PersistenceScript.TMP_SUFFIX), "no .tmp left behind")
	var text := FileAccess.get_file_as_string(path)
	_expect(errors, text == JSON.stringify(envelope, "", true, true), "file text is sorted full-precision JSON")

	var loaded = store.load_latest()
	if loaded == null:
		errors.append("load_latest returned null for a valid save")
		return
	_expect(errors, loaded.path == path, "load_latest picks the file just written")
	_expect(errors, loaded.saved_at_unix == 2042, "saved_at_unix restored")
	_expect(errors, _values_equal(loaded.round.to_dict(), round_state.to_dict()), "round restored")
	_expect(errors, _values_equal(loaded.players.to_save_array(), players.to_save_array()), "players restored")
	_expect(errors, _values_equal(loaded.world.to_save_dict(), world.to_save_dict()), "world restored")
	_expect(errors, loaded.world.tile_at(8, 0).owner == a and loaded.world.has_power_source(spawn_b.x, spawn_b.y), "world content restored")
	var again: Dictionary = PersistenceScript.build_envelope(loaded.world, loaded.players, loaded.round, 2042)
	_expect(errors, JSON.stringify(again, "", true, true) == text, "second envelope text equals first")

	# Rotation: five writes keep the newest three.
	for i in 4:
		OS.delay_msec(3)
		round_state.tick += 1
		var extra: String = store.write(PersistenceScript.build_envelope(world, players, round_state, 2050 + i))
		_expect(errors, extra != "", "rotation write %d" % i)
	var kept: PackedStringArray = store.list_saves()
	_expect(errors, kept.size() == PersistenceScript.KEEP_LATEST, "rotation keeps %d (got %d)" % [PersistenceScript.KEEP_LATEST, kept.size()])
	_expect(errors, not FileAccess.file_exists(path), "oldest save pruned")
	var newest = store.load_latest()
	_expect(errors, newest != null and newest.round.tick == 46, "newest save wins (tick %d)" % (newest.round.tick if newest != null else -1))

	# A corrupt newest file is skipped in favor of the previous good one.
	OS.delay_msec(3)
	var corrupt: String = store.dir.path_join(PersistenceScript.file_name_for(int(Time.get_unix_time_from_system() * 1000.0)))
	var handle := FileAccess.open(corrupt, FileAccess.WRITE)
	handle.store_string("{ not json")
	handle = null
	print("(expected: two push_error lines about the corrupt file follow)")
	var fallback = store.load_latest()
	_expect(errors, fallback != null and fallback.path == newest.path, "corrupt newest skipped")

	# A different save version is refused.
	var wrong: Dictionary = envelope.duplicate(true)
	wrong["version"] = SliceConstants.SAVE_FORMAT_VERSION + 1
	print("(expected: two push_error lines, save version and non-object, follow)")
	_expect(errors, PersistenceScript.parse_envelope(wrong, "wrong-version") == null, "version mismatch refused")
	_expect(errors, PersistenceScript.parse_envelope("text", "not-dict") == null, "non-object refused")

	# --new-round backup moves everything (3 good + 1 corrupt) out of the way.
	var before: int = store.list_saves().size()
	var dest: String = store.backup_all(3000)
	_expect(errors, dest != "" and dest.get_file().begins_with(PersistenceScript.BACKUP_PREFIX), "backup dir named (%s)" % dest)
	_expect(errors, store.list_saves().is_empty(), "saves moved out of the save dir")
	var moved := DirAccess.open(dest)
	_expect(errors, moved != null and moved.get_files().size() == before, "backup holds every file (%d)" % before)
	_expect(errors, store.backup_all(3001) == "", "second backup finds nothing")
	_expect(errors, store.load_latest() == null, "nothing loads after backup")
	_completed += 1


func _cleanup(scratch: String) -> void:
	var root: String = PersistenceScript.resolve_path(scratch)
	var handle := DirAccess.open(root)
	if handle == null:
		return
	for sub in handle.get_directories():
		var inner := DirAccess.open(root.path_join(sub))
		if inner != null:
			for file_name in inner.get_files():
				DirAccess.remove_absolute(root.path_join(sub).path_join(file_name))
		DirAccess.remove_absolute(root.path_join(sub))
	for file_name in handle.get_files():
		DirAccess.remove_absolute(root.path_join(file_name))
	DirAccess.remove_absolute(root)
	DirAccess.remove_absolute(root.get_base_dir())


func _apply_ok(errors: Array[String], world, faction: int, cmd: GameCommand, label: String) -> void:
	var result: Dictionary = world.apply(faction, cmd)
	if result["reason"] != ReasonCode.Id.OK:
		errors.append("setup %s rejected reason=%d detail=%s" % [label, result["reason"], result["detail"]])


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
	var a_num := a is int or a is float
	var b_num := b is int or b is float
	if a_num and b_num:
		return is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b


func _expect(errors: Array[String], cond: bool, message: String) -> void:
	if not cond:
		errors.append(message)

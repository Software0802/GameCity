class_name ServerPersistence
extends RefCounted

## Save envelope on disk, shape locked in docs/plans/m2-city-phase.md「存档信封」:
## {
##   "version": SliceConstants.SAVE_FORMAT_VERSION,
##   "saved_at_unix": int,
##   "round": {"started_at_unix", "ends_at_unix", "pace", "phase": "play"|"ended",
##             "crisis_fired", "tick"},
##   "players": [Players.Record.to_dict()],
##   "world": WorldState.to_save_dict()
## }
## "round.tick" is the server-core addition that lets status.json continue after a
## restart; everything else is the locked shape.
##
## One JSON file per snapshot, world-<utc timestamp>.json, written to a .tmp sibling
## and renamed into place. The newest KEEP_LATEST files are kept. Loading walks the
## files newest first and takes the first one whose envelope, players, and world all
## parse. JSON goes through to_dict() chains with full float precision; never
## var_to_bytes. Pure data: no Node, no RPC.


class RoundState:
	extends RefCounted

	var started_at_unix: int = 0
	var ends_at_unix: int = 0
	var pace: float = SliceConstants.PACE_DEFAULT
	var phase: String = PHASE_PLAY
	var crisis_fired: bool = false
	## Sim ticks run so far this round. Restored so status.json never starts over.
	var tick: int = 0

	func round_seconds() -> int:
		return ends_at_unix - started_at_unix

	func is_ended() -> bool:
		return phase == PHASE_ENDED

	func to_dict() -> Dictionary:
		return {
			"started_at_unix": started_at_unix,
			"ends_at_unix": ends_at_unix,
			"pace": pace,
			"phase": phase,
			"crisis_fired": crisis_fired,
			"tick": tick,
		}

	## Returns null when the clock is unusable (missing or inverted times, bad pace,
	## unknown phase).
	static func from_dict(data: Dictionary) -> RoundState:
		var round := RoundState.new()
		round.started_at_unix = int(data.get("started_at_unix", 0))
		round.ends_at_unix = int(data.get("ends_at_unix", 0))
		round.pace = float(data.get("pace", SliceConstants.PACE_DEFAULT))
		round.phase = str(data.get("phase", PHASE_PLAY))
		round.crisis_fired = bool(data.get("crisis_fired", false))
		round.tick = int(data.get("tick", 0))
		if round.started_at_unix <= 0 or round.ends_at_unix <= round.started_at_unix:
			return null
		if not (is_finite(round.pace) and round.pace > 0.0):
			return null
		if round.phase != PHASE_PLAY and round.phase != PHASE_ENDED:
			return null
		if round.tick < 0:
			round.tick = 0
		return round


class LoadedSave:
	extends RefCounted

	var path: String = ""
	var saved_at_unix: int = 0
	var round: RoundState = null
	var players: Players = null
	var world: WorldState = null


const PHASE_PLAY := "play"
const PHASE_ENDED := "ended"
const FILE_PREFIX := "world-"
const FILE_SUFFIX := ".json"
const TMP_SUFFIX := ".tmp"
const BACKUP_PREFIX := "backup-"
const KEEP_LATEST := 3

## Absolute directory the saves live in.
var dir: String = ""


func _init(save_dir: String) -> void:
	dir = resolve_path(save_dir)


## user:// and res:// go through ProjectSettings; absolute paths stay; anything else
## is relative to the process working directory (globalize_path leaves those alone).
static func resolve_path(path: String) -> String:
	if path.is_empty():
		return ""
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	if path.is_absolute_path():
		return path
	var cwd := DirAccess.open(".")
	if cwd == null:
		return path
	return cwd.get_current_dir().path_join(path)


func ensure_dir() -> Error:
	if DirAccess.dir_exists_absolute(dir):
		return OK
	return DirAccess.make_dir_recursive_absolute(dir)


## Absolute paths of every snapshot, oldest first. Names sort as timestamps.
func list_saves() -> PackedStringArray:
	var found := PackedStringArray()
	var handle := DirAccess.open(dir)
	if handle == null:
		return found
	for file_name in handle.get_files():
		if file_name.begins_with(FILE_PREFIX) and file_name.ends_with(FILE_SUFFIX):
			found.append(dir.path_join(file_name))
	found.sort()
	return found


## Newest snapshot that fully parses, or null. Each failure is logged and skipped.
func load_latest() -> LoadedSave:
	var saves := list_saves()
	for i in range(saves.size() - 1, -1, -1):
		var path := saves[i]
		var loaded := parse_envelope(read_json(path), path)
		if loaded != null:
			loaded.path = path
			return loaded
	return null


## Validates one envelope. Returns null (after push_error) when the version, round,
## players, or world cannot be loaded. label names the source in messages.
static func parse_envelope(data: Variant, label: String) -> LoadedSave:
	if not (data is Dictionary):
		push_error("save %s: not a JSON object" % label)
		return null
	var envelope: Dictionary = data
	var version := int(envelope.get("version", -1))
	if version != SliceConstants.SAVE_FORMAT_VERSION:
		push_error("save %s: version %d, expected %d" % [label, version, SliceConstants.SAVE_FORMAT_VERSION])
		return null
	var raw_round = envelope.get("round", null)
	if not (raw_round is Dictionary):
		push_error("save %s: missing round" % label)
		return null
	var round := RoundState.from_dict(raw_round)
	if round == null:
		push_error("save %s: round clock invalid %s" % [label, str(raw_round)])
		return null
	var raw_world = envelope.get("world", null)
	if not (raw_world is Dictionary):
		push_error("save %s: missing world" % label)
		return null
	var world := WorldState.from_save_dict(raw_world)
	if world == null:
		push_error("save %s: world did not load" % label)
		return null
	var loaded := LoadedSave.new()
	loaded.saved_at_unix = int(envelope.get("saved_at_unix", 0))
	loaded.round = round
	loaded.players = Players.from_save_array(envelope.get("players", []))
	loaded.world = world
	return loaded


static func build_envelope(world: WorldState, players: Players, round: RoundState, saved_at_unix: int) -> Dictionary:
	return {
		"version": SliceConstants.SAVE_FORMAT_VERSION,
		"saved_at_unix": saved_at_unix,
		"round": round.to_dict(),
		"players": players.to_save_array(),
		"world": world.to_save_dict(),
	}


## Writes one snapshot named from now and prunes to KEEP_LATEST. Returns the final
## path, or "" after push_error.
func write(envelope: Dictionary) -> String:
	var err := ensure_dir()
	if err != OK:
		push_error("save dir %s: %s" % [dir, error_string(err)])
		return ""
	var path := dir.path_join(file_name_for(int(Time.get_unix_time_from_system() * 1000.0)))
	err = write_json_atomic(path, envelope)
	if err != OK:
		push_error("save %s: %s" % [path, error_string(err)])
		return ""
	prune()
	return path


## Removes the oldest snapshots beyond keep. Returns how many were removed.
func prune(keep: int = KEEP_LATEST) -> int:
	var saves := list_saves()
	var removed := 0
	for i in range(0, saves.size() - keep):
		var err := DirAccess.remove_absolute(saves[i])
		if err == OK:
			removed += 1
		else:
			push_warning("prune %s: %s" % [saves[i], error_string(err)])
	return removed


## --new-round: moves every snapshot into backup-<timestamp>/ under dir so the next
## boot cannot pick the old round back up. Returns the backup directory, or "" when
## there was nothing to move. A file that fails to copy stays where it is.
func backup_all(now_unix: int) -> String:
	var saves := list_saves()
	if saves.is_empty():
		return ""
	var dest := dir.path_join(BACKUP_PREFIX + timestamp_text(now_unix * 1000))
	var err := DirAccess.make_dir_recursive_absolute(dest)
	if err != OK:
		push_error("backup dir %s: %s" % [dest, error_string(err)])
		return ""
	for path in saves:
		var target := dest.path_join(path.get_file())
		err = DirAccess.copy_absolute(path, target)
		if err != OK:
			push_error("backup copy %s: %s" % [path, error_string(err)])
			continue
		err = DirAccess.remove_absolute(path)
		if err != OK:
			push_warning("backup remove %s: %s" % [path, error_string(err)])
	return dest


## JSON.stringify with sorted keys and full float precision, written to path.tmp
## then renamed over path. The directory must exist.
static func write_json_atomic(path: String, data: Dictionary) -> Error:
	var tmp := path + TMP_SUFFIX
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data, "", true, true))
	file.flush()
	var write_err := file.get_error()
	file = null
	if write_err != OK:
		DirAccess.remove_absolute(tmp)
		return write_err
	return DirAccess.rename_absolute(tmp, path)


## Parsed JSON, or null when the file is missing or malformed (after push_error).
static func read_json(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("read %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return null
	var text := file.get_as_text()
	file = null
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("parse %s line %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


## world-YYYYMMDDTHHMMSS.mmmZ.json; lexical order is chronological order.
static func file_name_for(unix_ms: int) -> String:
	return FILE_PREFIX + timestamp_text(unix_ms) + FILE_SUFFIX


static func timestamp_text(unix_ms: int) -> String:
	var seconds := int(unix_ms / 1000)
	var millis := unix_ms - seconds * 1000
	var dt := Time.get_datetime_dict_from_unix_time(seconds)
	return "%04d%02d%02dT%02d%02d%02d.%03dZ" % [
		dt["year"], dt["month"], dt["day"], dt["hour"], dt["minute"], dt["second"], millis
	]

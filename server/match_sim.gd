extends Node

## Dedicated headless server entry, the root of res://server/main.tscn. Owns the boot
## sequence, the wall-clock round, the sim tick, crisis scheduling, FACTION_STATE
## cadence, periodic saves, the status file, and shutdown. Sessions, the handshake,
## and routing are GameNet (server/net_authority.gd).
##
##   godot --headless --path . res://server/main.tscn -- --port 24567 --save-dir /opt/gamecity/data
##
## Arguments after "--" (every one optional):
##   --port <int>            ENet UDP port (24567)
##   --save-dir <path>       user://, absolute, or cwd-relative (user://saves)
##   --save-interval <sec>   periodic save period (30)
##   --round-seconds <int>   length of a NEW round (SliceConstants.ROUND_SECONDS_DEFAULT);
##                           ignored when a save is restored, ends_at never moves
##   --pace <float>          WorldState.pace and MatchStart.pace (1.0); when given it
##                           overrides the pace stored in the save
##   --status-file <path>    write {tick, players, ...} there every second
##   --stop-file <path>      touch this file to save and exit 0 (<save-dir>/stop);
##                           "" disables. Headless Godot has no signal hook: SIGTERM
##                           kills the process without running anything, so this is
##                           the graceful stop, and periodic saves are the backstop.
##   --start-treasury <int>  starting treasury for BOTH factions of a NEW round, via
##                           WorldState.set_treasury_all(float); ignored when a save is
##                           restored, skipped (logged) until sim-economy adds the method
##   --free-build            WorldState.free_build = true (no costs once sim-economy lands)
##   --new-round             move old saves to backup-<ts>/ and start a fresh round
##   --smoke-host            legacy two-process smoke: seeds a scripted faction-A player
##                           that zones (0,0) R, adds edge (0,0)-(1,0) and claims (8,0);
##                           after SMOKE_REMOTE_COMMANDS remote commands sends
##                           MatchEnd{server_stop} and exits. Without --save-dir it
##                           writes nothing to disk.

const SMOKE_REMOTE_COMMANDS := 5
const SMOKE_QUIT_DELAY_SEC := 1.0
const STATUS_PERIOD_SEC := 1.0
const FACTION_STATE_PERIOD_SEC := 2.0
const CRISIS_ID := "grid_storm"
const DEFAULT_SAVE_DIR := "user://saves"
const DEFAULT_SAVE_INTERVAL := 30
const STOP_FILE_NAME := "stop"
const EXIT_BAD_ARGS := 2
const VALUE_FLAGS: Array[String] = [
	"--port", "--save-dir", "--save-interval", "--round-seconds", "--pace", "--status-file", "--stop-file",
	"--start-treasury",
]
const BOOL_FLAGS: Array[String] = ["--free-build", "--new-round", "--smoke-host"]


class Config:
	extends RefCounted

	var port: int = GameNet.DEFAULT_PORT
	var save_dir: String = DEFAULT_SAVE_DIR
	var save_dir_given := false
	var save_interval: int = DEFAULT_SAVE_INTERVAL
	var round_seconds: int = SliceConstants.ROUND_SECONDS_DEFAULT
	var pace: float = SliceConstants.PACE_DEFAULT
	var pace_given := false
	var status_file := ""
	var stop_file := ""
	var stop_file_given := false
	var start_treasury: int = 0
	var start_treasury_given := false
	var free_build := false
	var new_round := false
	var smoke_host := false
	var errors: Array[String] = []

	## Saves are written unless this is a --smoke-host run without an explicit --save-dir.
	func persist() -> bool:
		return save_dir_given or not smoke_host

	func summary() -> String:
		return "port=%d save_dir=%s save_interval=%d round_seconds=%d pace=%s status_file=%s stop_file=%s start_treasury=%s free_build=%s new_round=%s smoke_host=%s persist=%s" % [
			port, save_dir, save_interval, round_seconds, pace, status_file, stop_file,
			str(start_treasury) if start_treasury_given else "-",
			free_build, new_round, smoke_host, persist(),
		]


var config: Config = null
var persistence: ServerPersistence = null
var round_state: ServerPersistence.RoundState = null
var tick_index := 0
var saved_at_unix := 0
## True between the crisis start and end broadcasts of this process.
var crisis_active := false

var _status_path := ""
var _stop_path := ""
var _tick_timer: Timer
var _status_timer: Timer
var _save_timer: Timer
## faction → last FactionState dict sent / Time.get_ticks_msec() of that send.
var _last_faction_state: Dictionary = {}
var _last_faction_state_ms: Dictionary = {}
var _remote_commands := 0
var _smoke_stop_started := false
var _stopping := false
var _score_fallback_warned := false


func _ready() -> void:
	get_tree().auto_accept_quit = false
	config = parse_config(OS.get_cmdline_user_args())
	if not config.errors.is_empty():
		for err in config.errors:
			push_error("argument error: %s" % err)
		get_tree().quit(EXIT_BAD_ARGS)
		return
	print("Server config %s" % config.summary())
	var now := _now()
	var loaded: ServerPersistence.LoadedSave = null
	if config.persist():
		persistence = ServerPersistence.new(config.save_dir)
		var dir_err := persistence.ensure_dir()
		if dir_err != OK:
			push_error("save dir %s: %s" % [persistence.dir, error_string(dir_err)])
			get_tree().quit(1)
			return
		if config.new_round:
			var backup_dir := persistence.backup_all(now)
			if not backup_dir.is_empty():
				print("new round: previous saves moved to %s" % backup_dir)
		else:
			loaded = persistence.load_latest()
	var world: WorldState
	var players: Players
	if loaded != null:
		world = loaded.world
		players = loaded.players
		round_state = loaded.round
		tick_index = round_state.tick
		if config.pace_given:
			round_state.pace = config.pace
		print("restored %s: tick=%d phase=%s players=%d ends_at=%d pace=%s" % [
			loaded.path.get_file(), tick_index, round_state.phase, players.size(), round_state.ends_at_unix, round_state.pace,
		])
	else:
		world = WorldState.new()
		_apply_start_treasury(world)
		players = Players.new()
		round_state = ServerPersistence.RoundState.new()
		round_state.started_at_unix = now
		round_state.ends_at_unix = now + config.round_seconds
		round_state.pace = config.pace
		print("new round: %d s, started_at=%d ends_at=%d pace=%s" % [
			config.round_seconds, round_state.started_at_unix, round_state.ends_at_unix, round_state.pace,
		])
	_apply_world_flags(world)
	if config.smoke_host:
		_seed_smoke_host(world, players, now)
	GameNet.world = world
	GameNet.players = players
	GameNet.round_started_at_unix = round_state.started_at_unix
	GameNet.round_ends_at_unix = round_state.ends_at_unix
	GameNet.pace = round_state.pace
	GameNet.player_joined.connect(_on_player_joined)
	GameNet.command_handled.connect(_on_command_handled)
	var err := GameNet.start_server(config.port)
	if err != OK:
		push_error("ENet listen failed (%s)" % error_string(err))
		get_tree().quit(1)
		return
	if round_state.is_ended():
		GameNet.restore_match_end(_match_end_body(MatchEnd.REASON_CLOCK, 0))
		print("round already ended at %d; start with --new-round to begin a new one" % round_state.ends_at_unix)
	else:
		GameNet.set_phase(GameNet.Phase.PLAY)
	crisis_active = not round_state.is_ended() and round_state.crisis_fired and now < _crisis_end_unix()
	if round_state.crisis_fired:
		# The save may hold crisis_active from mid-storm; the clock decides whether the
		# storm is still on, so the world is synced to that (a no-op before sim-economy).
		_set_world_crisis(crisis_active)
	_status_path = ServerPersistence.resolve_path(config.status_file)
	_stop_path = _resolve_stop_path()
	_save("boot")
	_start_timers()
	_write_status()
	print("Server ready port=%d phase=%s tick=%d players_known=%d seconds_remaining=%d" % [
		config.port, round_state.phase, tick_index, players.size(), _seconds_remaining(now),
	])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_shutdown("wm_close")


# ---------------------------------------------------------------- CLI


static func parse_config(args: PackedStringArray) -> Config:
	var config := Config.new()
	var i := 0
	while i < args.size():
		var flag := args[i]
		if BOOL_FLAGS.has(flag):
			match flag:
				"--free-build":
					config.free_build = true
				"--new-round":
					config.new_round = true
				"--smoke-host":
					config.smoke_host = true
			i += 1
			continue
		if not VALUE_FLAGS.has(flag):
			config.errors.append("unknown argument %s" % flag)
			i += 1
			continue
		if i + 1 >= args.size() or args[i + 1].begins_with("--"):
			config.errors.append("%s needs a value" % flag)
			i += 1
			continue
		var value := args[i + 1]
		i += 2
		match flag:
			"--port":
				config.port = _int_arg(config, flag, value, 1, 65535)
			"--save-dir":
				if value.is_empty():
					config.errors.append("--save-dir needs a path")
				else:
					config.save_dir = value
					config.save_dir_given = true
			"--save-interval":
				config.save_interval = _int_arg(config, flag, value, 1, 86400)
			"--round-seconds":
				config.round_seconds = _int_arg(config, flag, value, 1, 1 << 40)
			"--pace":
				if value.is_valid_float() and is_finite(float(value)) and float(value) > 0.0:
					config.pace = float(value)
					config.pace_given = true
				else:
					config.errors.append("--pace must be a positive number, got %s" % value)
			"--status-file":
				config.status_file = value
			"--stop-file":
				config.stop_file = value
				config.stop_file_given = true
			"--start-treasury":
				config.start_treasury = _int_arg(config, flag, value, 0, 1 << 40)
				config.start_treasury_given = true
	return config


static func _int_arg(config: Config, flag: String, value: String, low: int, high: int) -> int:
	if not value.is_valid_int():
		config.errors.append("%s must be an integer, got %s" % [flag, value])
		return low
	var parsed := int(value)
	if parsed < low or parsed > high:
		config.errors.append("%s must be in %d..%d, got %d" % [flag, low, high, parsed])
		return low
	return parsed


# ---------------------------------------------------------------- boot helpers


## pace and free_build belong to sim-economy's WorldState; until that lands the
## properties may not exist, so both writes are guarded.
func _apply_world_flags(world: WorldState) -> void:
	if "pace" in world:
		world.set("pace", round_state.pace)
	else:
		print("WorldState has no pace property yet; --pace only reaches MatchStart")
	if "free_build" in world:
		world.set("free_build", config.free_build)
	elif config.free_build:
		print("WorldState has no free_build property yet; --free-build recorded only")


## --start-treasury on a fresh world only (first boot or --new-round); a restored save
## keeps its treasuries. WorldState.set_treasury_all(float) is sim-economy's seam and
## is skipped with a log line until it lands.
func _apply_start_treasury(world: WorldState) -> void:
	if not config.start_treasury_given:
		return
	if world.has_method("set_treasury_all"):
		world.call("set_treasury_all", float(config.start_treasury))
		print("start treasury %d applied via set_treasury_all" % config.start_treasury)
	else:
		print("WorldState has no set_treasury_all yet; start treasury %d recorded only" % config.start_treasury)


## The old listen-host player, kept for client/smoke_client.gd: a scripted faction-A
## row so the first real joiner balances to B, plus the three commands the host used
## to send once the match began.
func _seed_smoke_host(world: WorldState, players: Players, now: int) -> void:
	if players.size() == 0:
		players.create("smoke-host", SliceConstants.Owner.FACTION_A, "", now)
	var scripted: Array[GameCommand] = [
		GameCommand.set_zone(0, 0, SliceConstants.Zone.R),
		GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 0)),
		GameCommand.claim_tile(8, 0),
	]
	for cmd in scripted:
		var result: Dictionary = world.apply(SliceConstants.Owner.FACTION_A, cmd)
		print("smoke-host faction=0 kind=%d reason=%d" % [cmd.kind, int(result["reason"])])


func _resolve_stop_path() -> String:
	if config.stop_file_given:
		return ServerPersistence.resolve_path(config.stop_file)
	if persistence == null:
		return ""
	return persistence.dir.path_join(STOP_FILE_NAME)


func _start_timers() -> void:
	_tick_timer = _make_timer("SimTick", SliceConstants.SIM_TICK_SEC, _on_tick)
	_status_timer = _make_timer("Status", STATUS_PERIOD_SEC, _on_status_timer)
	if persistence != null:
		_save_timer = _make_timer("Save", float(config.save_interval), _on_save_timer)


func _make_timer(timer_name: String, period: float, callback: Callable) -> Timer:
	var timer := Timer.new()
	timer.name = timer_name
	timer.wait_time = period
	timer.timeout.connect(callback)
	add_child(timer)
	timer.start()
	return timer


# ---------------------------------------------------------------- tick


func _on_tick() -> void:
	if _stopping or GameNet.phase != GameNet.Phase.PLAY:
		return
	tick_index += 1
	round_state.tick = tick_index
	var now := _now()
	var world: WorldState = GameNet.world
	var forward: Array = []
	for event in world.sim_tick(tick_index):
		# The sim's own ScoreTick carries no clock; the one below replaces it.
		if int(event.kind) != ServerEvent.Kind.SCORE_TICK:
			forward.append(event)
	GameNet.publish(forward)
	_crisis_step(now)
	var remaining := _seconds_remaining(now)
	var score := _score_tick(remaining)
	GameNet.broadcast([ServerEvent.with_score_tick(score)])
	_faction_state_step()
	if remaining <= 0:
		_end_by_clock(score)


func _seconds_remaining(now: int) -> int:
	return maxi(0, round_state.ends_at_unix - now)


## ScoreTick for this tick. sim-economy provides score(seconds_remaining); until it
## lands, the wave 0 _score(tick_index, seconds_remaining) path is used.
func _score_tick(remaining: int) -> ScoreTick:
	var world: WorldState = GameNet.world
	var score: ScoreTick = null
	if world.has_method("score"):
		score = world.call("score", remaining)
	elif world.has_method("_score"):
		score = world.call("_score", tick_index, remaining)
	if score == null:
		if not _score_fallback_warned:
			_score_fallback_warned = true
			push_warning("WorldState has neither score() nor _score(); ScoreTick has no faction lines")
		score = ScoreTick.new()
	score.tick_index = tick_index
	score.seconds_remaining = remaining
	return score


func _end_by_clock(score: ScoreTick) -> void:
	round_state.phase = ServerPersistence.PHASE_ENDED
	var body := MatchEnd.new()
	body.reason = MatchEnd.REASON_CLOCK
	body.final_scores = score
	body.winner = _winner(score)
	GameNet.end_round(body)
	_save("round_end")


## Highest weighted total wins; an exact tie (both sides equal) has no winner.
static func _winner(score: ScoreTick) -> int:
	var best := SliceConstants.Owner.NEUTRAL
	var best_total := -INF
	var tied := false
	for line in score.factions:
		var total: float = line.total()
		if is_equal_approx(total, best_total):
			tied = true
		elif total > best_total:
			best_total = total
			best = line.faction
			tied = false
	if tied:
		return SliceConstants.Owner.NEUTRAL
	return best


func _match_end_body(reason: String, remaining: int) -> MatchEnd:
	var body := MatchEnd.new()
	body.reason = reason
	body.final_scores = _score_tick(remaining)
	body.winner = _winner(body.final_scores) if reason == MatchEnd.REASON_CLOCK else SliceConstants.Owner.NEUTRAL
	return body


# ---------------------------------------------------------------- crisis


func _crisis_start_unix() -> int:
	return round_state.started_at_unix + int(floor(float(round_state.round_seconds()) * SliceConstants.CRISIS_AT_FRACTION))


func _crisis_end_unix() -> int:
	return _crisis_start_unix() + SliceConstants.CRISIS_DURATION_SEC


## Fires the grid storm once per round at CRISIS_AT_FRACTION and clears it
## CRISIS_DURATION_SEC later. crisis_fired is saved so a restart never refires;
## whether the storm is still running is derived from the clock.
func _crisis_step(now: int) -> void:
	if not round_state.crisis_fired:
		if now >= _crisis_start_unix():
			round_state.crisis_fired = true
			crisis_active = true
			_set_world_crisis(true)
			GameNet.broadcast([ServerEvent.with_crisis_event(_crisis_event(true))])
			print("crisis %s start, ends_at=%d" % [CRISIS_ID, _crisis_end_unix()])
	elif crisis_active and now >= _crisis_end_unix():
		crisis_active = false
		_set_world_crisis(false)
		GameNet.broadcast([ServerEvent.with_crisis_event(_crisis_event(false))])
		print("crisis %s end" % CRISIS_ID)


## WorldState.set_crisis(active) is sim-economy's seam; absent until it lands.
func _set_world_crisis(active: bool) -> void:
	var world: WorldState = GameNet.world
	if world.has_method("set_crisis"):
		world.call("set_crisis", active)


func _crisis_event(active: bool) -> CrisisEvent:
	var event := CrisisEvent.new()
	event.crisis_id = CRISIS_ID
	event.kind = CrisisEvent.KIND_GRID_STORM
	event.active = active
	event.detail = "shared"
	# CrisisEvent contract: ends_at_unix is 0 when active is false.
	event.ends_at_unix = _crisis_end_unix() if active else 0
	return event


# ---------------------------------------------------------------- faction state


## WorldState.faction_states() is sim-economy's seam; absent until it lands. Each
## faction's state goes to that faction's players when it changes or every
## FACTION_STATE_PERIOD_SEC, whichever comes first.
func _faction_state_step() -> void:
	var now_ms := Time.get_ticks_msec()
	for state in _faction_states():
		var key := int(state.faction)
		var body: Dictionary = state.to_dict()
		var due := now_ms - int(_last_faction_state_ms.get(key, -1_000_000)) >= int(FACTION_STATE_PERIOD_SEC * 1000.0)
		if due or body != _last_faction_state.get(key, {}):
			GameNet.send_faction(key, [ServerEvent.with_faction_state(state)])
			_last_faction_state[key] = body
			_last_faction_state_ms[key] = now_ms


func _faction_states() -> Array:
	var world: WorldState = GameNet.world
	if world == null or not world.has_method("faction_states"):
		return []
	var states = world.call("faction_states")
	if states is Array:
		return states
	return []


## A fresh connection gets its faction's state and the running storm right after
## its snapshot; GameNet already sent MATCH_END if the round is over.
func _on_player_joined(peer_id: int, _player_id: int, joined_faction: int, _returning: bool) -> void:
	var extras: Array = []
	for state in _faction_states():
		if int(state.faction) == joined_faction:
			extras.append(ServerEvent.with_faction_state(state))
	if crisis_active:
		extras.append(ServerEvent.with_crisis_event(_crisis_event(true)))
	if not extras.is_empty():
		GameNet.send_peer(peer_id, extras)


# ---------------------------------------------------------------- smoke host


func _on_command_handled(_peer_id: int, _cmd: GameCommand, _reason: int) -> void:
	if not config.smoke_host or _smoke_stop_started:
		return
	_remote_commands += 1
	if _remote_commands >= SMOKE_REMOTE_COMMANDS:
		_smoke_stop_started = true
		_smoke_stop.call_deferred()


func _smoke_stop() -> void:
	round_state.phase = ServerPersistence.PHASE_ENDED
	GameNet.end_round(_match_end_body(MatchEnd.REASON_SERVER_STOP, _seconds_remaining(_now())))
	get_tree().create_timer(SMOKE_QUIT_DELAY_SEC).timeout.connect(_shutdown.bind("smoke_stop"))


# ---------------------------------------------------------------- status, save, stop


func _on_status_timer() -> void:
	if _stopping:
		return
	_write_status()
	if not _stop_path.is_empty() and FileAccess.file_exists(_stop_path):
		DirAccess.remove_absolute(_stop_path)
		_shutdown("stop_file")


func _write_status() -> void:
	if _status_path.is_empty():
		return
	var status := {
		"tick": tick_index,
		"players": GameNet.online_count(),
		"players_known": GameNet.players.size(),
		"round_ends_at_unix": round_state.ends_at_unix,
		"saved_at_unix": saved_at_unix,
		"pid": OS.get_process_id(),
		"phase": round_state.phase,
	}
	var err := ServerPersistence.write_json_atomic(_status_path, status)
	if err != OK:
		push_warning("status file %s: %s" % [_status_path, error_string(err)])


func _on_save_timer() -> void:
	if not _stopping:
		_save("interval")


func _save(reason: String) -> void:
	if persistence == null:
		return
	var now := _now()
	GameNet.touch_online_players(now)
	var envelope := ServerPersistence.build_envelope(GameNet.world, GameNet.players, round_state, now)
	var path := persistence.write(envelope)
	if path.is_empty():
		return
	saved_at_unix = now
	print("saved %s (%s) tick=%d" % [path.get_file(), reason, tick_index])


## Saves, closes the socket, and quits 0. Reached from the stop file, a window
## close request, or the smoke host's scripted stop.
func _shutdown(reason: String) -> void:
	if _stopping:
		return
	_stopping = true
	for timer in [_tick_timer, _status_timer, _save_timer]:
		if timer != null:
			timer.stop()
	_save("shutdown:" + reason)
	_write_status()
	GameNet.close_peer()
	print("Server stop: %s" % reason)
	get_tree().quit(0)


static func _now() -> int:
	return int(floor(Time.get_unix_time_from_system()))

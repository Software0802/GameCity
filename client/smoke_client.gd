extends Node

## Headless smoke peer for tests/run_smoke.sh. One process is one scripted player.
##
##   godot --headless --path . res://client/smoke_client.tscn -- --join 127.0.0.1 --port 24671 \
##       [--scenario legacy|idle|a|b|broke] [--expect server_stop|clock|none] \
##       [--name <1-24 chars>] [--identity-file <path>] [--hold-seconds <n>] [--round-seconds <n>]
##
## Scenarios (coordinates derive from the faction the server assigns, never from the label):
##   legacy  wave-0 path against --smoke-host: this peer is faction B, claims the tile west of
##           its corner, zones it C, adds an edge, and sends two illegal commands at A's spawn.
##           Default scenario; default --expect server_stop. Keeps step 3 of run_smoke.sh green.
##   idle    hello, WELCOME, MATCH_START, no commands. Holds --hold-seconds, then exits.
##   a       idle plus one claim on the opponent's spawn corner; passes on REJECT OPPONENT_IMMUTABLE.
##           Builds nothing, so the other side wins the round on score.
##   b       builds an R tile with a road and power just outside its own spawn corner
##           (claim, zone R, edge, power). On a returning connection where the tile already
##           shows all of that, sends nothing and only verifies.
##   broke   two claims next to its own spawn; passes when the second one is rejected
##           INSUFFICIENT_FUNDS and that tile stays neutral (step 7, no --free-build).
##
## --expect: server_stop waits for MatchEnd{server_stop}; clock waits for MatchEnd{clock} with
## final_scores and a non-NEUTRAL winner (scenario b also requires winner == own faction);
## none exits after the scenario plus --hold-seconds. With --expect clock the deadline is
## --round-seconds + 15 s, tightened to round_ends_at_unix + 15 s once MATCH_START arrives.
##
## Handshake: after the transport connects, hello_rpc is sent when GameNet has it. Without it
## the peer prints NO_HELLO_RPC; legacy continues on the wave-0 path, every other scenario
## fails at once because it cannot get a WELCOME.
##
## One machine-readable line per message (tests/run_smoke.sh parses these):
##   SMOKE_START ... | NO_HELLO_RPC | HELLO name= token=present|empty protocol=
##   WELCOME player_id= faction= returning= name= | IDENTITY_SAVED path=
##   MATCH_START round_seconds= round_ends_at_unix= server_unix= pace= | CLOCK remaining_s=
##   FACTION_STATE faction= treasury= income= pop= jobs= tax= | TILE x,y owner= zone= ...
##   EDGE x,y-x,y removed= | REJECT kind= reason= name= tile=x,y detail=
##   CRISIS kind= active= | MATCH_END reason= winner= final_scores= seconds_remaining=
##   SCENARIO_DONE ... | SMOKE_OK | SMOKE_FAIL <why>

const BASE_DEADLINE_MS := 20000
const CLOCK_MARGIN_SEC := 15
const JOIN_RETRY_MS := 2000
## Block snapshots arrive as several RPC batches; wait this long after the first watched
## tile shows up before deciding what scenario b still has to build.
const SNAPSHOT_SETTLE_MS := 300
const SCENARIOS: Array[String] = ["legacy", "idle", "a", "b", "broke"]
const EXPECTS: Array[String] = ["server_stop", "clock", "none"]

## Legacy scenario: this peer is faction B. CLAIM_B is the neutral tile just west of the
## corner; EDGE_B spans the corner tile and its east neighbor, both inside the spawn.
const CLAIM_B: Vector2i = WorldState.SPAWN_B + Vector2i(-1, 0)
const EDGE_B_A: Vector2i = WorldState.SPAWN_B
const EDGE_B_B: Vector2i = WorldState.SPAWN_B + Vector2i(1, 0)


## Minimal identity file, same path and keys as the client-play ClientIdentity class
## (user://identity.cfg, keys token and name). Replace with ClientIdentity once it lands.
class Identity:
	extends RefCounted

	const DEFAULT_PATH := "user://identity.cfg"
	const SECTION := "identity"

	var path: String = DEFAULT_PATH
	var token: String = ""
	var name: String = ""

	func _init(p_path: String = DEFAULT_PATH) -> void:
		path = p_path

	## Missing file is not an error: token and name stay empty.
	func read() -> Error:
		var config := ConfigFile.new()
		var err := config.load(path)
		if err == ERR_FILE_NOT_FOUND or err == ERR_FILE_CANT_OPEN:
			return OK
		if err != OK:
			return err
		token = str(config.get_value(SECTION, "token", ""))
		name = str(config.get_value(SECTION, "name", ""))
		return OK

	func write() -> Error:
		var dir := ProjectSettings.globalize_path(path).get_base_dir()
		if dir != "":
			var made := DirAccess.make_dir_recursive_absolute(dir)
			if made != OK and made != ERR_ALREADY_EXISTS:
				return made
		var config := ConfigFile.new()
		config.set_value(SECTION, "token", token)
		config.set_value(SECTION, "name", name)
		return config.save(path)


var session: ClientSession
var identity: Identity
var scenario := "legacy"
var expect := "server_stop"
var player_name := "smoke"
var hold_seconds := 0
var round_seconds_arg := 60

var _deadline_ms: int = 0
var _online := false
var _joining := false
var _join_started_ms := 0
var _next_join_ms := 0
var _done := false
var _fail := ""
var _faction: int = SliceConstants.Owner.NEUTRAL
var _hello_sent := false
var _hello_missing := false
var _welcome: ServerWelcome = null
var _match_start: MatchStart = null
var _commands_sent := false
var _scenario_done := false
var _scenario_done_ms := 0
var _snapshot_seen_ms := 0
var _server_gone := false
var _last_faction_state := ""


func _ready() -> void:
	session = $Session
	scenario = GameNet.arg_value("--scenario", "legacy")
	var default_expect := "server_stop" if scenario == "legacy" else "none"
	expect = GameNet.arg_value("--expect", default_expect)
	player_name = GameNet.arg_value("--name", "smoke")
	hold_seconds = maxi(0, int(GameNet.arg_value("--hold-seconds", "0")))
	round_seconds_arg = maxi(1, int(GameNet.arg_value("--round-seconds", "60")))
	identity = Identity.new(GameNet.arg_value("--identity-file", Identity.DEFAULT_PATH))
	if not SCENARIOS.has(scenario):
		_fail = "unknown --scenario %s (use %s)" % [scenario, ", ".join(SCENARIOS)]
		_finish(1)
		return
	if not EXPECTS.has(expect):
		_fail = "unknown --expect %s (use %s)" % [expect, ", ".join(EXPECTS)]
		_finish(1)
		return
	if not ClientHello.is_valid_name(player_name):
		_fail = "--name must be %d-%d characters" % [ClientHello.NAME_MIN, ClientHello.NAME_MAX]
		_finish(1)
		return
	var read_err := identity.read()
	if read_err != OK:
		_fail = "identity read failed %s path=%s" % [error_string(read_err), identity.path]
		_finish(1)
		return
	_deadline_ms = Time.get_ticks_msec() + _initial_deadline_ms()
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	GameNet.faction_assigned.connect(_on_faction_assigned)
	GameNet.event_received.connect(_on_event)
	# Deferred so the event's own log line prints before any SMOKE_OK it triggers; the
	# session (a child, connected first) would otherwise run _check inside its handler.
	session.updated.connect(_check, CONNECT_DEFERRED)
	print("SMOKE_START scenario=%s expect=%s name=%s identity=%s token=%s hold_s=%d deadline_s=%d" % [
		scenario,
		expect,
		player_name,
		identity.path,
		"present" if identity.token != "" else "empty",
		hold_seconds,
		int((_deadline_ms - Time.get_ticks_msec()) / 1000),
	])
	_try_join()


func _process(_delta: float) -> void:
	if _done:
		return
	var now := Time.get_ticks_msec()
	if not _online and _joining and now - _join_started_ms > JOIN_RETRY_MS:
		GameNet.close_peer()
		_joining = false
		_next_join_ms = now + 200
	if not _online and not _joining and not _server_gone and now >= _next_join_ms:
		_try_join()
	if now > _deadline_ms:
		_fail = "timeout " + _diagnose()
		_finish(1)
		return
	_check()


func _initial_deadline_ms() -> int:
	if expect == "clock":
		return (round_seconds_arg + CLOCK_MARGIN_SEC) * 1000
	return BASE_DEADLINE_MS + hold_seconds * 1000


func _try_join() -> void:
	_joining = true
	_join_started_ms = Time.get_ticks_msec()
	var err := GameNet.join(GameNet.host_from_args(), GameNet.port_from_args())
	if err != OK:
		_joining = false
		_next_join_ms = Time.get_ticks_msec() + 200


func _on_connected() -> void:
	_online = true
	_joining = false
	# hello_rpc is server-core's RPC. Autoload members are checked at parse time, so it is
	# looked up dynamically; a baseline GameNet without it keeps this script loadable.
	if GameNet.has_method("hello_rpc"):
		var hello := ClientHello.new()
		hello.token = identity.token
		hello.name = player_name
		GameNet.rpc_id(1, "hello_rpc", hello.to_dict())
		_hello_sent = true
		print("HELLO name=%s token=%s protocol=%d" % [
			player_name,
			"present" if identity.token != "" else "empty",
			hello.protocol,
		])
		return
	_hello_missing = true
	print("NO_HELLO_RPC")
	# With --expect clock the round clock is checked first (at MATCH_START), so a server that
	# lacks both the handshake and the clock reports the clock; the handshake fails right after.
	if scenario != "legacy" and expect != "clock":
		_fail_no_hello()


func _fail_no_hello() -> void:
	_fail = "NO_HELLO_RPC: GameNet.hello_rpc missing, scenario %s needs WELCOME (server-core handshake not merged)" % scenario
	_finish(1)


func _on_connection_failed() -> void:
	_online = false
	_joining = false
	GameNet.close_peer()
	_next_join_ms = Time.get_ticks_msec() + 200


func _on_server_disconnected() -> void:
	_server_gone = true
	_online = false
	print("SERVER_DISCONNECTED")


func _on_faction_assigned(faction: int) -> void:
	# Wave-0 welcome_rpc(faction). WELCOME overrides it when both arrive.
	if _welcome == null:
		_faction = faction
		print("FACTION_ASSIGNED faction=%d" % faction)


func _on_event(event: ServerEvent) -> void:
	# Session (a child) applies the event before this handler runs, so its caches are current.
	match event.kind:
		ServerEvent.Kind.WELCOME:
			_on_welcome(event.welcome)
		ServerEvent.Kind.MATCH_START:
			_on_match_start(event.match_start)
		ServerEvent.Kind.FACTION_STATE:
			_on_faction_state(event.faction_state)
		ServerEvent.Kind.TILE_DELTA:
			_on_tile_delta(event.tile_delta)
		ServerEvent.Kind.EDGE_DELTA:
			_on_edge_delta(event.edge_delta)
		ServerEvent.Kind.REJECT:
			_on_reject(event.reject)
		ServerEvent.Kind.CRISIS_EVENT:
			if event.crisis_event != null:
				print("CRISIS kind=%s active=%s id=%s" % [
					event.crisis_event.kind, event.crisis_event.active, event.crisis_event.crisis_id
				])
		ServerEvent.Kind.MATCH_END:
			_on_match_end(event.match_end)


func _on_welcome(welcome: ServerWelcome) -> void:
	if welcome == null:
		return
	_welcome = welcome
	_faction = welcome.faction
	print("WELCOME player_id=%d faction=%d returning=%s name=%s" % [
		welcome.player_id, welcome.faction, welcome.returning, welcome.name
	])
	identity.token = welcome.token
	identity.name = welcome.name if welcome.name != "" else player_name
	var err := identity.write()
	if err != OK:
		_fail = "identity write failed %s path=%s" % [error_string(err), identity.path]
		_finish(1)
		return
	print("IDENTITY_SAVED path=%s" % identity.path)


func _on_match_start(start: MatchStart) -> void:
	if start == null:
		return
	_match_start = start
	print("MATCH_START round_seconds=%d round_ends_at_unix=%d server_unix=%d pace=%.3f map_size=%d" % [
		start.round_seconds, start.round_ends_at_unix, start.server_unix, start.pace, start.map_size
	])
	if expect == "clock":
		_check_clock(start)
		if not _done and _hello_missing and scenario != "legacy":
			_fail_no_hello()


## Fail fast when the server has no usable round clock instead of waiting out the deadline.
func _check_clock(start: MatchStart) -> void:
	if start.round_ends_at_unix <= 0:
		_fail = "MATCH_START round_ends_at_unix=0: server has no round clock (--round-seconds not implemented, server-core)"
		_finish(1)
		return
	var now_unix := start.server_unix
	if now_unix <= 0:
		now_unix = int(Time.get_unix_time_from_system())
	var remaining := start.round_ends_at_unix - now_unix
	if remaining > round_seconds_arg + CLOCK_MARGIN_SEC:
		_fail = "server round ends in %d s, expected <= %d s: --round-seconds %d not honored (server-core)" % [
			remaining, round_seconds_arg + CLOCK_MARGIN_SEC, round_seconds_arg
		]
		_finish(1)
		return
	var refined := Time.get_ticks_msec() + (maxi(remaining, 0) + CLOCK_MARGIN_SEC) * 1000
	_deadline_ms = mini(_deadline_ms, refined)
	print("CLOCK remaining_s=%d deadline_s=%d" % [
		remaining, int((_deadline_ms - Time.get_ticks_msec()) / 1000)
	])


func _on_faction_state(state: FactionState) -> void:
	if state == null:
		return
	var line := "FACTION_STATE faction=%d treasury=%.2f income=%.3f pop=%d jobs=%d tax=%.2f power=%d/%d" % [
		state.faction, state.treasury, state.income_per_sec, state.population, state.jobs,
		state.tax_rate, state.power_load, state.power_capacity
	]
	if line == _last_faction_state:
		return
	_last_faction_state = line
	print(line)


func _on_tile_delta(tile: TileDelta) -> void:
	if tile == null or not _watched_tiles().has(Vector2i(tile.x, tile.y)):
		return
	print("TILE %d,%d owner=%d zone=%d building=%s tier=%d power=%s brownout=%s" % [
		tile.x, tile.y, tile.owner, tile.zone, tile.has_building, tile.building_tier,
		tile.power_covered, tile.brownout
	])


func _on_edge_delta(edge: EdgeDelta) -> void:
	if edge == null:
		return
	var watched := _watched_tiles()
	if not watched.has(edge.a) and not watched.has(edge.b):
		return
	print("EDGE %d,%d-%d,%d removed=%s" % [edge.a.x, edge.a.y, edge.b.x, edge.b.y, edge.removed])


func _on_reject(reject: CommandReject) -> void:
	if reject == null:
		return
	var tile := "-"
	if reject.command != null:
		if reject.command.kind == GameCommand.Kind.ADD_EDGE or reject.command.kind == GameCommand.Kind.REMOVE_EDGE:
			tile = "%d,%d-%d,%d" % [
				reject.command.edge_a.x, reject.command.edge_a.y,
				reject.command.edge_b.x, reject.command.edge_b.y,
			]
		else:
			tile = "%d,%d" % [reject.command.tile_x, reject.command.tile_y]
	print("REJECT kind=%d reason=%d name=%s tile=%s detail=%s" % [
		reject.kind, reject.reason, _reason_name(reject.reason), tile, reject.detail
	])


func _on_match_end(end: MatchEnd) -> void:
	if end == null:
		return
	var seconds := -1
	if end.final_scores != null:
		seconds = end.final_scores.seconds_remaining
	print("MATCH_END reason=%s winner=%d final_scores=%s seconds_remaining=%d" % [
		end.reason, end.winner, end.final_scores != null, seconds
	])
	if end.final_scores != null:
		for line in end.final_scores.factions:
			print("FINAL_SCORE faction=%d total=%.3f pop=%.3f fiscal=%.3f control=%.3f pop_raw=%.1f fiscal_raw=%.1f control_raw=%.1f" % [
				line.faction, line.total(), line.pop, line.fiscal, line.control,
				line.pop_raw, line.fiscal_raw, line.control_raw
			])
	if scenario != "legacy" and not _scenario_done:
		_fail = "MatchEnd %s arrived before scenario %s finished: %s" % [end.reason, scenario, _diagnose()]
		_finish(1)


func _check() -> void:
	if _done or session == null:
		return
	if scenario == "legacy":
		_check_legacy()
		return
	if not _scenario_done:
		if not _ready_for_commands():
			return
		_run_scenario()
		if _done or not _scenario_done:
			return
	_check_end()


## Commands before WELCOME are NOT_AUTHENTICATED, so wait for it whenever hello was sent.
func _ready_for_commands() -> bool:
	if not session.match_started:
		return false
	if _hello_sent and _welcome == null:
		return false
	return _faction != SliceConstants.Owner.NEUTRAL


func _run_scenario() -> void:
	match scenario:
		"idle":
			_scenario_done = true
		"a":
			_scenario_a()
		"b":
			_scenario_b()
		"broke":
			_scenario_broke()
	if _scenario_done and _scenario_done_ms == 0:
		_scenario_done_ms = Time.get_ticks_msec()
		print("SCENARIO_DONE scenario=%s faction=%d" % [scenario, _faction])


func _scenario_a() -> void:
	var corner := _spawn_origin(_opponent())
	if not _commands_sent:
		_commands_sent = true
		session.send_command(GameCommand.claim_tile(corner.x, corner.y))
		return
	var reject := _reject_for(GameCommand.Kind.CLAIM_TILE, corner)
	if reject != null:
		if reject.reason == ReasonCode.Id.OPPONENT_IMMUTABLE:
			_scenario_done = true
			return
		_fail = "claim on opponent corner %s rejected %s, expected OPPONENT_IMMUTABLE" % [
			corner, _reason_name(reject.reason)
		]
		_finish(1)
		return
	if _tile_owner(corner) == _faction:
		_fail = "claim on opponent corner %s was accepted" % corner
		_finish(1)


func _scenario_b() -> void:
	var out := _tile_out(_faction)
	var inn := _tile_in(_faction)
	var tile: TileDelta = session.tile(out.x, out.y)
	if tile == null:
		return
	var now := Time.get_ticks_msec()
	if _snapshot_seen_ms == 0:
		_snapshot_seen_ms = now
	if not _commands_sent:
		if now - _snapshot_seen_ms < SNAPSHOT_SETTLE_MS:
			return
		_commands_sent = true
		var sent := 0
		if tile.owner != _faction:
			session.send_command(GameCommand.claim_tile(out.x, out.y))
			sent += 1
		if tile.zone != SliceConstants.Zone.R:
			session.send_command(GameCommand.set_zone(out.x, out.y, SliceConstants.Zone.R))
			sent += 1
		if session.edge(out, inn) == null:
			session.send_command(GameCommand.add_edge(out, inn))
			sent += 1
		if not tile.power_covered:
			session.send_command(GameCommand.place_power(inn.x, inn.y))
			sent += 1
		print("BUILD faction=%d tile=%d,%d sent=%d" % [_faction, out.x, out.y, sent])
		if sent > 0:
			return
	var reject := _first_reject_touching([out, inn])
	if reject != null:
		_fail = "build command kind=%d on %s rejected %s detail=%s" % [
			reject.kind, out, _reason_name(reject.reason), reject.detail
		]
		_finish(1)
		return
	if _built(out, inn):
		_scenario_done = true


func _scenario_broke() -> void:
	var first := _tile_out(_faction)
	var second := _tile_out2(_faction)
	if not _commands_sent:
		_commands_sent = true
		session.send_command(GameCommand.claim_tile(first.x, first.y))
		session.send_command(GameCommand.claim_tile(second.x, second.y))
		return
	var reject1 := _reject_for(GameCommand.Kind.CLAIM_TILE, first)
	var reject2 := _reject_for(GameCommand.Kind.CLAIM_TILE, second)
	var owner1 := _tile_owner(first)
	var owner2 := _tile_owner(second)
	var settled1 := reject1 != null or owner1 == _faction
	var settled2 := reject2 != null or owner2 == _faction
	if not (settled1 and settled2):
		return
	if owner2 == _faction:
		_fail = "second claim %s accepted: no claim cost applied (sim-economy economy not merged, or --free-build is on)" % second
		_finish(1)
		return
	if reject2.reason != ReasonCode.Id.INSUFFICIENT_FUNDS:
		_fail = "second claim %s rejected %s, expected INSUFFICIENT_FUNDS" % [second, _reason_name(reject2.reason)]
		_finish(1)
		return
	var first_result := "accepted"
	if reject1 != null:
		if reject1.reason != ReasonCode.Id.INSUFFICIENT_FUNDS:
			_fail = "first claim %s rejected %s" % [first, _reason_name(reject1.reason)]
			_finish(1)
			return
		first_result = "INSUFFICIENT_FUNDS"
		print("BROKE_DIAG first claim also INSUFFICIENT_FUNDS: COST_CLAIM_BASE %d * (1 + COST_CLAIM_GROWTH %.2f * owned) exceeds the start treasury; raise SMOKE_START_TREASURY if the first claim should pass" % [
			SliceConstants.COST_CLAIM_BASE, SliceConstants.COST_CLAIM_GROWTH
		])
	print("BROKE_OK first=%s second=INSUFFICIENT_FUNDS" % first_result)
	_scenario_done = true


func _check_end() -> void:
	var end: MatchEnd = session.match_end
	match expect:
		"none":
			if end != null and end.reason == MatchEnd.REASON_SERVER_STOP:
				print("HOLD_INTERRUPTED reason=%s" % end.reason)
				_ok()
			elif end != null:
				_fail = "MatchEnd %s during hold" % end.reason
				_finish(1)
			elif _server_gone:
				print("HOLD_INTERRUPTED reason=disconnected")
				_ok()
			elif Time.get_ticks_msec() - _scenario_done_ms >= hold_seconds * 1000:
				_ok()
		"server_stop":
			if end == null:
				return
			if end.reason != MatchEnd.REASON_SERVER_STOP:
				_fail = "MatchEnd reason=%s expected server_stop" % end.reason
				_finish(1)
				return
			_ok()
		"clock":
			if end == null:
				return
			if end.reason != MatchEnd.REASON_CLOCK:
				_fail = "MatchEnd reason=%s expected clock" % end.reason
				_finish(1)
				return
			if end.final_scores == null:
				_fail = "MatchEnd{clock} without final_scores"
				_finish(1)
				return
			if end.winner == SliceConstants.Owner.NEUTRAL:
				_fail = "MatchEnd{clock} winner NEUTRAL"
				_finish(1)
				return
			if scenario == "b" and end.winner != _faction:
				_fail = "MatchEnd{clock} winner %d but the only builder is faction %d" % [end.winner, _faction]
				_finish(1)
				return
			_ok()


## Wave-0 assertions, unchanged: zone/edge/reject/rollback against --smoke-host.
func _check_legacy() -> void:
	if session.match_started and not _commands_sent:
		if _hello_sent and _welcome == null:
			return
		_commands_sent = true
		GameNet.set_camera_local(0, 0)
		session.send_command(GameCommand.claim_tile(CLAIM_B.x, CLAIM_B.y))
		session.send_command(GameCommand.claim_tile(0, 0))
		session.send_command(GameCommand.set_zone(CLAIM_B.x, CLAIM_B.y, SliceConstants.Zone.C))
		session.send_command(GameCommand.add_edge(EDGE_B_A, EDGE_B_B))
		session.send_command(GameCommand.add_edge(Vector2i(0, 0), Vector2i(0, 1)))
	if not _commands_sent or session.match_end == null:
		return
	var spawn: TileDelta = session.tile(0, 0)
	var claimed: TileDelta = session.tile(CLAIM_B.x, CLAIM_B.y)
	var host_edge: EdgeDelta = session.edge(Vector2i(0, 0), Vector2i(1, 0))
	var own_edge: EdgeDelta = session.edge(EDGE_B_A, EDGE_B_B)
	if spawn == null or spawn.zone != SliceConstants.Zone.R:
		return
	if host_edge == null or host_edge.removed:
		return
	if claimed == null or claimed.owner != SliceConstants.Owner.FACTION_B:
		return
	if claimed.zone != SliceConstants.Zone.C:
		return
	if own_edge == null or own_edge.removed:
		return
	if not session.saw_reject(
		ReasonCode.Id.OPPONENT_IMMUTABLE,
		GameCommand.Kind.CLAIM_TILE,
		Vector2i(0, 0)
	):
		return
	if not session.saw_reject(
		ReasonCode.Id.OPPONENT_IMMUTABLE,
		GameCommand.Kind.ADD_EDGE,
		Vector2i(0, 0),
		Vector2i(0, 1)
	):
		return
	if session.match_end.winner != SliceConstants.Owner.NEUTRAL:
		_fail = "winner %s" % session.match_end.winner
		_finish(1)
		return
	var want_reason := MatchEnd.REASON_CLOCK if expect == "clock" else MatchEnd.REASON_SERVER_STOP
	if session.match_end.reason != want_reason:
		_fail = "reason %s expected %s" % [session.match_end.reason, want_reason]
		_finish(1)
		return
	if session.pending_count() != 0:
		_fail = "pending %d" % session.pending_count()
		_finish(1)
		return
	if session.view_tile(0, 0).owner != SliceConstants.Owner.FACTION_A:
		_fail = "rollback owner %s" % session.view_tile(0, 0).owner
		_finish(1)
		return
	_ok()


func _built(out: Vector2i, inn: Vector2i) -> bool:
	var tile: TileDelta = session.tile(out.x, out.y)
	if tile == null:
		return false
	var edge: EdgeDelta = session.edge(out, inn)
	return (
		tile.owner == _faction
		and tile.zone == SliceConstants.Zone.R
		and tile.has_building
		and tile.power_covered
		and edge != null
		and not edge.removed
	)


func _opponent() -> int:
	if _faction == SliceConstants.Owner.FACTION_A:
		return SliceConstants.Owner.FACTION_B
	return SliceConstants.Owner.FACTION_A


func _spawn_origin(faction: int) -> Vector2i:
	if faction == SliceConstants.Owner.FACTION_B:
		return WorldState.SPAWN_B
	return WorldState.SPAWN_A


## Neutral tile just outside the faction's spawn corner, orthogonally adjacent to it.
func _tile_out(faction: int) -> Vector2i:
	if faction == SliceConstants.Owner.FACTION_B:
		return WorldState.SPAWN_B + Vector2i(-1, 0)
	return WorldState.SPAWN_A + Vector2i(WorldState.SPAWN_SIZE, 0)


## Spawn tile next to _tile_out: edge endpoint and power plant site.
func _tile_in(faction: int) -> Vector2i:
	if faction == SliceConstants.Owner.FACTION_B:
		return WorldState.SPAWN_B
	return WorldState.SPAWN_A + Vector2i(WorldState.SPAWN_SIZE - 1, 0)


## Second neutral tile adjacent to the spawn, independent of _tile_out's outcome.
func _tile_out2(faction: int) -> Vector2i:
	return _tile_out(faction) + Vector2i(0, 1)


func _watched_tiles() -> Array[Vector2i]:
	var watched: Array[Vector2i] = []
	if scenario == "legacy":
		watched.append(CLAIM_B)
		watched.append(Vector2i(0, 0))
		return watched
	if _faction == SliceConstants.Owner.NEUTRAL:
		return watched
	watched.append(_tile_out(_faction))
	watched.append(_tile_in(_faction))
	watched.append(_tile_out2(_faction))
	watched.append(_spawn_origin(_opponent()))
	return watched


func _tile_owner(at: Vector2i) -> int:
	var tile: TileDelta = session.tile(at.x, at.y)
	if tile == null:
		return SliceConstants.Owner.NEUTRAL
	return tile.owner


func _reject_for(kind: int, at: Vector2i) -> CommandReject:
	for reject in session.rejects:
		if reject.command == null or reject.command.kind != kind:
			continue
		if reject.command.tile_x == at.x and reject.command.tile_y == at.y:
			return reject
	return null


func _first_reject_touching(tiles: Array[Vector2i]) -> CommandReject:
	for reject in session.rejects:
		if reject.command == null:
			continue
		var cmd: GameCommand = reject.command
		if cmd.kind == GameCommand.Kind.ADD_EDGE or cmd.kind == GameCommand.Kind.REMOVE_EDGE:
			if tiles.has(cmd.edge_a) or tiles.has(cmd.edge_b):
				return reject
		elif tiles.has(Vector2i(cmd.tile_x, cmd.tile_y)):
			return reject
	return null


func _diagnose() -> String:
	if scenario == "legacy":
		return _debug_state_legacy()
	if not _online and not _server_gone:
		return "never connected to %s:%d" % [GameNet.host_from_args(), GameNet.port_from_args()]
	if _hello_missing:
		return "NO_HELLO_RPC: GameNet.hello_rpc missing (server-core handshake not merged)"
	if _hello_sent and _welcome == null:
		return "hello_rpc sent, no WELCOME (server-core handshake)"
	if not session.match_started and session.match_end == null:
		return "WELCOME ok, no MATCH_START"
	if not _scenario_done:
		return "scenario %s unfinished: %s rejects=%d" % [scenario, _tile_report(), session.rejects.size()]
	if expect == "clock":
		var ends := -1
		var server_unix := -1
		if _match_start != null:
			ends = _match_start.round_ends_at_unix
			server_unix = _match_start.server_unix
		return "no MatchEnd{clock}; MATCH_START round_ends_at_unix=%d server_unix=%d now_unix=%d (round clock / --round-seconds, server-core)" % [
			ends, server_unix, int(Time.get_unix_time_from_system())
		]
	if expect == "server_stop":
		return "no MatchEnd{server_stop}"
	return "hold not finished"


func _tile_report() -> String:
	var parts: Array[String] = []
	for at in _watched_tiles():
		var tile: TileDelta = session.tile(at.x, at.y)
		if tile == null:
			parts.append("%d,%d=unseen" % [at.x, at.y])
		else:
			parts.append("%d,%d=owner%d/zone%d/power%s" % [at.x, at.y, tile.owner, tile.zone, tile.power_covered])
	if scenario == "b" and _faction != SliceConstants.Owner.NEUTRAL:
		parts.append("edge=%s" % (session.edge(_tile_out(_faction), _tile_in(_faction)) != null))
	return " ".join(parts)


func _debug_state_legacy() -> String:
	var spawn: TileDelta = session.tile(0, 0)
	var claimed: TileDelta = session.tile(CLAIM_B.x, CLAIM_B.y)
	var zone0 := -1 if spawn == null else spawn.zone
	var owner_claim := -99 if claimed == null else claimed.owner
	var zone_claim := -1 if claimed == null else claimed.zone
	var end_reason := ""
	if session.match_end != null:
		end_reason = session.match_end.reason
	return "match=%s zone0=%s owner%s=%s zone%s=%s edgeA=%s edgeB=%s rejects=%d end=%s pending=%d hello=%s welcome=%s" % [
		session.match_started,
		zone0,
		CLAIM_B,
		owner_claim,
		CLAIM_B,
		zone_claim,
		session.edge(Vector2i(0, 0), Vector2i(1, 0)) != null,
		session.edge(EDGE_B_A, EDGE_B_B) != null,
		session.rejects.size(),
		end_reason,
		session.pending_count(),
		"missing" if _hello_missing else ("sent" if _hello_sent else "pending"),
		_welcome != null,
	]


func _reason_name(code: int) -> String:
	var keys := ReasonCode.Id.keys()
	var values := ReasonCode.Id.values()
	var idx := values.find(code)
	if idx == -1:
		return str(code)
	return str(keys[idx])


func _ok() -> void:
	print("SMOKE_OK")
	_finish(0)


func _finish(code: int) -> void:
	if _done:
		return
	_done = true
	if code != 0:
		print("SMOKE_FAIL %s" % _fail)
	print("SUMMARY scenario=%s expect=%s faction=%d welcome=%s returning=%s match_started=%s end=%s exit=%d" % [
		scenario,
		expect,
		_faction,
		_welcome != null,
		_welcome != null and _welcome.returning,
		session != null and session.match_started,
		"-" if session == null or session.match_end == null else session.match_end.reason,
		code,
	])
	get_tree().quit(code)

extends Node

## Headless check client for server/server_core_check.sh. Talks to GameNet directly
## (client/session.gd belongs to client-play) and prints one result line per phase:
##   CLIENT_OK name=.. player_id=.. faction=.. returning=.. token=.. claimed=x,y|- owned=x,y|- early_reject=..
##   CLIENT_END reason=.. winner=.. final_scores=true|false crisis_seen=.. post_end_reject=..
##   CLIENT_REFUSED detail=.. disconnected=..      (expected for --protocol <wrong>)
##   CLIENT_FAIL <why>                              (exit 1)
##   godot --headless --path . res://server/check_client.tscn -- --join 127.0.0.1 --port 24567 --name alice --claim
## Flags after "--":
##   --join <host> --port <p>   server (GameNet defaults: 127.0.0.1, 24567)
##   --name <n>                 hello name (default from GameNet: "player")
##   --token <t>                hello token
##   --token-file <path>        read the token from this file when it exists and --token is
##                              absent; the issued token is written there after WELCOME
##   --protocol <int>           hello protocol; anything but PROTOCOL_VERSION expects a refusal
##   --early-command            send a claim before hello and expect Reject(NOT_AUTHENTICATED)
##   --claim                    after MATCH_START claim the tile next to own spawn and wait
##                              for the TileDelta that confirms it
##   --expect-owned <x,y>       fail unless that tile arrives owned by this faction
##   --wait-end                 stay until MATCH_END, then send a claim and expect
##                              Reject(MATCH_NOT_ACTIVE)
##   --hold <sec>               keep the connection open this long after the checks pass
##   --deadline <sec>           overall timeout (30)

const JOIN_RETRY_MS := 2000
const DEFAULT_DEADLINE_SEC := 30.0

var _name := ""
var _token := ""
var _token_file := ""
var _protocol: int = SliceConstants.PROTOCOL_VERSION
var _early_command := false
var _claim := false
var _expect_owned := Vector2i(-1, -1)
var _wait_end := false
var _hold_sec := 0.0
var _deadline_ms := 0

var _online := false
var _joining := false
var _join_started_ms := 0
var _next_join_ms := 0
var _done := false
var _welcome: ServerWelcome = null
var _match_started := false
var _claim_target := Vector2i(-1, -1)
var _claim_sent := false
var _claim_confirmed := false
var _owned_seen := false
var _early_sent := false
var _early_reject := ""
var _refusal_detail := ""
var _match_end: MatchEnd = null
var _crisis_seen := false
var _post_end_sent := false
var _post_end_reject := ""
var _checks_passed_ms := -1
var _tiles: Dictionary = {}


func _ready() -> void:
	_parse_args()
	_deadline_ms = Time.get_ticks_msec() + int(DEFAULT_DEADLINE_SEC * 1000.0)
	var deadline := GameNet.arg_value("--deadline", "")
	if deadline.is_valid_float():
		_deadline_ms = Time.get_ticks_msec() + int(float(deadline) * 1000.0)
	GameNet.auto_hello = false
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	GameNet.welcomed.connect(_on_welcomed)
	GameNet.event_received.connect(_on_event)
	GameNet.connection_lost.connect(_on_connection_lost)
	_try_join()


func _parse_args() -> void:
	_name = GameNet.arg_value("--name", "")
	_token = GameNet.arg_value("--token", "")
	_token_file = GameNet.arg_value("--token-file", "")
	if _token.is_empty() and not _token_file.is_empty() and FileAccess.file_exists(_token_file):
		_token = FileAccess.get_file_as_string(_token_file).strip_edges()
	var protocol := GameNet.arg_value("--protocol", "")
	if protocol.is_valid_int():
		_protocol = int(protocol)
	_early_command = GameNet.has_flag("--early-command")
	_claim = GameNet.has_flag("--claim")
	var owned := GameNet.arg_value("--expect-owned", "")
	if owned.contains(","):
		var parts := owned.split(",")
		_expect_owned = Vector2i(int(parts[0]), int(parts[1]))
	_wait_end = GameNet.has_flag("--wait-end")
	var hold := GameNet.arg_value("--hold", "")
	if hold.is_valid_float():
		_hold_sec = float(hold)


func _process(_delta: float) -> void:
	if _done:
		return
	var now := Time.get_ticks_msec()
	if not _online and _joining and now - _join_started_ms > JOIN_RETRY_MS:
		GameNet.close_peer()
		_joining = false
		_next_join_ms = now + 200
	if not _online and not _joining and now >= _next_join_ms:
		_try_join()
	if now > _deadline_ms:
		_fail("deadline: %s" % _state_text())
		return
	_check()


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
	if _early_command:
		_early_sent = true
		GameNet.submit_local(GameCommand.claim_tile(8, 0))
	else:
		GameNet.hello(_name, _token, _protocol)


func _on_connection_failed() -> void:
	_online = false
	_joining = false
	GameNet.close_peer()
	_next_join_ms = Time.get_ticks_msec() + 200


func _on_connection_lost() -> void:
	if _done:
		return
	if _protocol != SliceConstants.PROTOCOL_VERSION:
		print("CLIENT_REFUSED detail=%s disconnected=true" % _refusal_detail)
		_finish(0)
		return
	_fail("connection lost: %s" % _state_text())


func _on_welcomed(welcome: ServerWelcome) -> void:
	_welcome = welcome
	if _protocol != SliceConstants.PROTOCOL_VERSION:
		_fail("welcomed with protocol %d" % _protocol)
		return
	if not _token_file.is_empty():
		var file := FileAccess.open(_token_file, FileAccess.WRITE)
		if file != null:
			file.store_string(welcome.token)
	if _claim:
		_claim_target = _own_claim_tile(welcome.faction)


## The neutral tile just outside this faction's spawn corner, derived from the
## spawn constants: A claims east of its corner, B claims west of its corner.
static func _own_claim_tile(faction: int) -> Vector2i:
	if faction == SliceConstants.Owner.FACTION_B:
		return WorldState.SPAWN_B + Vector2i(-1, 0)
	return WorldState.SPAWN_A + Vector2i(WorldState.SPAWN_SIZE, 0)


func _on_event(event: ServerEvent) -> void:
	match event.kind:
		ServerEvent.Kind.MATCH_START:
			_match_started = true
			if _claim and not _claim_sent and _welcome != null:
				_claim_sent = true
				GameNet.submit_local(GameCommand.claim_tile(_claim_target.x, _claim_target.y))
		ServerEvent.Kind.TILE_DELTA:
			if event.tile_delta == null:
				return
			var tile := event.tile_delta
			_tiles[tile.id] = tile
			if _welcome == null:
				return
			if _claim and tile.x == _claim_target.x and tile.y == _claim_target.y and tile.owner == _welcome.faction:
				_claim_confirmed = true
			if tile.x == _expect_owned.x and tile.y == _expect_owned.y and tile.owner == _welcome.faction:
				_owned_seen = true
		ServerEvent.Kind.REJECT:
			if event.reject == null:
				return
			var reason: int = event.reject.reason
			if _welcome == null and _early_sent and _early_reject.is_empty() and reason == ReasonCode.Id.NOT_AUTHENTICATED:
				_early_reject = "NOT_AUTHENTICATED"
				GameNet.hello(_name, _token, _protocol)
				return
			if _welcome == null and reason == ReasonCode.Id.NOT_AUTHENTICATED:
				_refusal_detail = event.reject.detail
				return
			if _post_end_sent and _post_end_reject.is_empty():
				_post_end_reject = ReasonCode.Id.keys()[reason] if reason < ReasonCode.Id.size() else str(reason)
				return
			if _claim_sent and not _claim_confirmed and event.reject.command != null and event.reject.command.kind == GameCommand.Kind.CLAIM_TILE:
				_fail("claim rejected reason=%d detail=%s" % [reason, event.reject.detail])
		ServerEvent.Kind.CRISIS_EVENT:
			if event.crisis_event != null and event.crisis_event.kind == CrisisEvent.KIND_GRID_STORM and event.crisis_event.active:
				_crisis_seen = true
		ServerEvent.Kind.MATCH_END:
			if event.match_end == null:
				return
			_match_end = event.match_end
			if _wait_end and not _post_end_sent:
				_post_end_sent = true
				GameNet.submit_local(GameCommand.claim_tile(_own_claim_tile(_welcome.faction).x, _own_claim_tile(_welcome.faction).y))


func _check() -> void:
	if _done or _welcome == null:
		return
	if not _match_started:
		return
	if _claim and not _claim_confirmed:
		return
	if _expect_owned.x >= 0 and not _owned_seen:
		return
	if _early_command and _early_reject.is_empty():
		return
	if _wait_end and (_match_end == null or _post_end_reject.is_empty()):
		return
	if _checks_passed_ms < 0:
		_checks_passed_ms = Time.get_ticks_msec()
		print("CLIENT_OK name=%s player_id=%d faction=%d returning=%s token=%s claimed=%s owned=%s early_reject=%s" % [
			_welcome.name,
			_welcome.player_id,
			_welcome.faction,
			_welcome.returning,
			_welcome.token,
			_point_text(_claim_target) if _claim else "-",
			_point_text(_expect_owned) if _expect_owned.x >= 0 else "-",
			_early_reject if _early_command else "-",
		])
		if _wait_end:
			print("CLIENT_END reason=%s winner=%d final_scores=%s crisis_seen=%s post_end_reject=%s" % [
				_match_end.reason,
				_match_end.winner,
				_match_end.final_scores != null and _match_end.final_scores.factions.size() == SliceConstants.FACTION_COUNT,
				_crisis_seen,
				_post_end_reject,
			])
	if Time.get_ticks_msec() - _checks_passed_ms >= int(_hold_sec * 1000.0):
		_finish(0)


static func _point_text(point: Vector2i) -> String:
	return "%d,%d" % [point.x, point.y]


func _state_text() -> String:
	return "online=%s welcomed=%s match_started=%s claim_sent=%s claim_confirmed=%s owned_seen=%s early_reject=%s match_end=%s post_end_reject=%s tiles=%d" % [
		_online,
		_welcome != null,
		_match_started,
		_claim_sent,
		_claim_confirmed,
		_owned_seen,
		_early_reject,
		_match_end != null,
		_post_end_reject,
		_tiles.size(),
	]


func _fail(why: String) -> void:
	if _done:
		return
	print("CLIENT_FAIL %s" % why)
	_finish(1)


func _finish(code: int) -> void:
	if _done:
		return
	_done = true
	GameNet.close_peer()
	get_tree().quit(code)

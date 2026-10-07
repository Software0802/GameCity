extends Node

## Headless joiner. Retries until the listen-host is up, then exchanges commands.
##   godot --headless --path . res://client/smoke_client.tscn -- --join 127.0.0.1 --port 24671

const DEADLINE_MS := 20000
const JOIN_RETRY_MS := 2000
## This peer is faction B. Its targets derive from B's spawn corner, never a literal:
## CLAIM_B is the neutral tile just west of the corner; EDGE_B spans the corner tile
## and its east neighbor, both inside the spawn.
const CLAIM_B: Vector2i = WorldState.SPAWN_B + Vector2i(-1, 0)
const EDGE_B_A: Vector2i = WorldState.SPAWN_B
const EDGE_B_B: Vector2i = WorldState.SPAWN_B + Vector2i(1, 0)

var session: ClientSession
var _deadline_ms: int = 0
var _commands_sent := false
var _online := false
var _joining := false
var _join_started_ms := 0
var _next_join_ms := 0
var _done := false
var _fail := ""


func _ready() -> void:
	session = $Session
	_deadline_ms = Time.get_ticks_msec() + DEADLINE_MS
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	session.updated.connect(_check)
	_try_join()


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
		_fail = _debug_state()
		_finish(1)
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


func _on_connection_failed() -> void:
	_online = false
	_joining = false
	GameNet.close_peer()
	_next_join_ms = Time.get_ticks_msec() + 200


func _check() -> void:
	if _done or session == null:
		return
	if session.match_started and not _commands_sent:
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
	if session.match_end.reason != MatchEnd.REASON_SERVER_STOP:
		_fail = "reason %s" % session.match_end.reason
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
	print("SMOKE_OK")
	_finish(0)


func _debug_state() -> String:
	var spawn: TileDelta = session.tile(0, 0)
	var claimed: TileDelta = session.tile(CLAIM_B.x, CLAIM_B.y)
	var zone0 := -1 if spawn == null else spawn.zone
	var owner_claim := -99 if claimed == null else claimed.owner
	var zone_claim := -1 if claimed == null else claimed.zone
	var end_reason := ""
	if session.match_end != null:
		end_reason = session.match_end.reason
	return "timeout match=%s zone0=%s owner%s=%s zone%s=%s edgeA=%s edgeB=%s rejects=%d end=%s pending=%d" % [
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
	]


func _finish(code: int) -> void:
	if _done:
		return
	_done = true
	if code != 0:
		print("SMOKE_FAIL %s" % _fail)
	get_tree().quit(code)

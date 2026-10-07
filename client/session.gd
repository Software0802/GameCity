class_name ClientSession
extends Node

## Thin client mirror. Sends intents and applies authoritative events.
## Optimistic overlay lives only in `pending` and is dropped on Reject or MatchEnd.

signal updated

var faction: int = SliceConstants.Owner.NEUTRAL
var match_started: bool = false
var match_end: MatchEnd = null
var last_reject: CommandReject = null
var rejects: Array[CommandReject] = []
var last_score: ScoreTick = null

var _tiles: Dictionary = {}
var _edges: Dictionary = {}
var _summaries: Dictionary = {}
var _subscribed: Dictionary = {}
var _pending: Array[GameCommand] = []


func _ready() -> void:
	GameNet.faction_assigned.connect(_on_faction)
	GameNet.event_received.connect(_on_event)


func send_command(cmd: GameCommand) -> void:
	if cmd == null:
		return
	_pending.append(cmd)
	GameNet.submit_local(cmd)
	updated.emit()


func pending_count() -> int:
	return _pending.size()


func tile(x: int, y: int) -> TileDelta:
	var id := SliceConstants.tile_id(x, y)
	if not _tiles.has(id):
		return null
	return _tiles[id]


func edge(a: Vector2i, b: Vector2i) -> EdgeDelta:
	var key := WorldState.edge_key(a, b)
	if not _edges.has(key):
		return null
	return _edges[key]


func view_tile(x: int, y: int) -> TileDelta:
	var base := TileDelta.from_cell(x, y)
	var current := tile(x, y)
	if current != null:
		base = TileDelta.from_dict(current.to_dict())
	for cmd in _pending:
		if cmd.tile_x != x or cmd.tile_y != y:
			continue
		match cmd.kind:
			GameCommand.Kind.CLAIM_TILE:
				base.owner = faction
			GameCommand.Kind.SET_ZONE:
				base.zone = cmd.zone
				base.has_building = cmd.zone != SliceConstants.Zone.NONE
			GameCommand.Kind.DEMOLISH_OWN:
				base.has_building = false
				base.building_tier = 0
			GameCommand.Kind.PLACE_POWER:
				base.power_covered = true
			GameCommand.Kind.REMOVE_POWER:
				base.power_covered = false
	return base


func saw_reject(reason: int, kind: int, a: Vector2i, b: Vector2i = Vector2i(-1, -1)) -> bool:
	for reject in rejects:
		if reject.reason != reason or reject.command == null:
			continue
		if reject.command.kind != kind:
			continue
		if kind == GameCommand.Kind.ADD_EDGE or kind == GameCommand.Kind.REMOVE_EDGE:
			if WorldState.same_edge(reject.command.edge_a, reject.command.edge_b, a, b):
				return true
		elif reject.command.tile_x == a.x and reject.command.tile_y == a.y:
			return true
	return false


func status_text(cursor: Vector2i) -> String:
	var view := view_tile(cursor.x, cursor.y)
	var reject_text := "-"
	if last_reject != null:
		reject_text = "%s %s" % [_reason_name(last_reject.reason), last_reject.detail]
	var phase := "lobby"
	if match_end != null:
		phase = "ended %s" % match_end.reason
	elif match_started:
		phase = "play"
	return "GameCity listen-host  %s\nfaction %s  cursor %d,%d  view_owner %s zone %s\npending %d  reject %s" % [
		phase,
		_faction_name(faction),
		cursor.x,
		cursor.y,
		_faction_name(view.owner),
		_zone_name(view.zone),
		_pending.size(),
		reject_text,
	]


func _on_faction(assigned: int) -> void:
	faction = assigned
	updated.emit()


func _on_event(event: ServerEvent) -> void:
	_apply(event)
	updated.emit()


func _apply(event: ServerEvent) -> void:
	match event.kind:
		ServerEvent.Kind.MATCH_START:
			match_started = true
			match_end = null
			_tiles.clear()
			_edges.clear()
			_summaries.clear()
			_subscribed.clear()
			_pending.clear()
			rejects.clear()
			last_reject = null
		ServerEvent.Kind.MATCH_END:
			match_end = event.match_end
			match_started = false
			_pending.clear()
		ServerEvent.Kind.TILE_DELTA:
			if event.tile_delta == null:
				return
			var tile := TileDelta.from_dict(event.tile_delta.to_dict())
			if not _block_open(tile.x, tile.y):
				_tiles.erase(tile.id)
				return
			_tiles[tile.id] = tile
			_clear_pending_tile(tile.x, tile.y)
		ServerEvent.Kind.EDGE_DELTA:
			if event.edge_delta == null:
				return
			var delta := event.edge_delta
			var key := WorldState.edge_key(delta.a, delta.b)
			if not _edge_open(delta.a, delta.b):
				_edges.erase(key)
				return
			if delta.removed:
				_edges.erase(key)
			else:
				_edges[key] = EdgeDelta.from_dict(delta.to_dict())
			_clear_pending_edge(delta.a, delta.b)
		ServerEvent.Kind.REJECT:
			if event.reject == null:
				return
			last_reject = event.reject
			rejects.append(event.reject)
			_clear_pending_command(event.reject.command)
		ServerEvent.Kind.INTEREST_UPDATE:
			if event.interest_update == null:
				return
			_apply_interest(event.interest_update)
		ServerEvent.Kind.REGION_SUMMARY:
			if event.region_summary != null and event.region_summary.interest != null:
				_summaries[event.region_summary.interest.key()] = event.region_summary
		ServerEvent.Kind.CONGESTION_ALERT:
			if event.congestion_alert == null:
				return
			var alert := event.congestion_alert
			var edge_key := WorldState.edge_key(alert.a, alert.b)
			if _edges.has(edge_key):
				_edges[edge_key].congestion = alert.congestion
		ServerEvent.Kind.POWER_ALERT:
			if event.power_alert == null:
				return
			var id := SliceConstants.tile_id(event.power_alert.x, event.power_alert.y)
			if _tiles.has(id):
				_tiles[id].power_covered = event.power_alert.power_covered
		ServerEvent.Kind.SCORE_TICK:
			last_score = event.score_tick
		ServerEvent.Kind.CRISIS_EVENT:
			pass


func _apply_interest(update: InterestUpdate) -> void:
	for block in update.add:
		if block != null:
			_subscribed[block.key()] = true
	for block in update.remove:
		if block != null:
			_subscribed.erase(block.key())
	_forget_outside_subscription()


func _forget_outside_subscription() -> void:
	for id in _tiles.keys():
		var body: TileDelta = _tiles[id]
		if not _block_open(body.x, body.y):
			_tiles.erase(id)
	for key in _edges.keys():
		var body: EdgeDelta = _edges[key]
		if not _edge_open(body.a, body.b):
			_edges.erase(key)


func _block_open(x: int, y: int) -> bool:
	return _subscribed.has(InterestId.from_tile(x, y).key())


func _edge_open(a: Vector2i, b: Vector2i) -> bool:
	return _block_open(a.x, a.y) or _block_open(b.x, b.y)


func _clear_pending_tile(x: int, y: int) -> void:
	var kept: Array[GameCommand] = []
	for cmd in _pending:
		var tile_cmd := (
			cmd.kind == GameCommand.Kind.CLAIM_TILE
			or cmd.kind == GameCommand.Kind.SET_ZONE
			or cmd.kind == GameCommand.Kind.DEMOLISH_OWN
			or cmd.kind == GameCommand.Kind.PLACE_POWER
			or cmd.kind == GameCommand.Kind.REMOVE_POWER
		)
		if tile_cmd and cmd.tile_x == x and cmd.tile_y == y:
			continue
		kept.append(cmd)
	_pending = kept


func _clear_pending_edge(a: Vector2i, b: Vector2i) -> void:
	var kept: Array[GameCommand] = []
	for cmd in _pending:
		var edge_cmd := cmd.kind == GameCommand.Kind.ADD_EDGE or cmd.kind == GameCommand.Kind.REMOVE_EDGE
		if edge_cmd and WorldState.same_edge(cmd.edge_a, cmd.edge_b, a, b):
			continue
		kept.append(cmd)
	_pending = kept


func _clear_pending_command(cmd: GameCommand) -> void:
	if cmd == null:
		return
	var kept: Array[GameCommand] = []
	var removed := false
	for pending in _pending:
		if not removed and _same_command(pending, cmd):
			removed = true
			continue
		kept.append(pending)
	_pending = kept


func _same_command(a: GameCommand, b: GameCommand) -> bool:
	if a.kind != b.kind:
		return false
	if a.kind == GameCommand.Kind.ADD_EDGE or a.kind == GameCommand.Kind.REMOVE_EDGE:
		return WorldState.same_edge(a.edge_a, a.edge_b, b.edge_a, b.edge_b)
	return a.tile_x == b.tile_x and a.tile_y == b.tile_y and a.zone == b.zone


func _faction_name(owner: int) -> String:
	match owner:
		SliceConstants.Owner.FACTION_A:
			return "A"
		SliceConstants.Owner.FACTION_B:
			return "B"
		_:
			return "neutral"


func _zone_name(zone: int) -> String:
	match zone:
		SliceConstants.Zone.R:
			return "R"
		SliceConstants.Zone.C:
			return "C"
		SliceConstants.Zone.I:
			return "I"
		_:
			return "none"


func _reason_name(code: int) -> String:
	match code:
		ReasonCode.Id.OK:
			return "OK"
		ReasonCode.Id.NOT_IMPLEMENTED:
			return "NOT_IMPLEMENTED"
		ReasonCode.Id.UNKNOWN_COMMAND:
			return "UNKNOWN_COMMAND"
		ReasonCode.Id.MATCH_NOT_ACTIVE:
			return "MATCH_NOT_ACTIVE"
		ReasonCode.Id.OUT_OF_BOUNDS:
			return "OUT_OF_BOUNDS"
		ReasonCode.Id.NOT_NEUTRAL:
			return "NOT_NEUTRAL"
		ReasonCode.Id.NOT_ADJACENT:
			return "NOT_ADJACENT"
		ReasonCode.Id.NOT_OWNER:
			return "NOT_OWNER"
		ReasonCode.Id.OPPONENT_IMMUTABLE:
			return "OPPONENT_IMMUTABLE"
		ReasonCode.Id.INVALID_ZONE:
			return "INVALID_ZONE"
		ReasonCode.Id.NOT_ORTHOGONAL:
			return "NOT_ORTHOGONAL"
		ReasonCode.Id.EDGE_RULE:
			return "EDGE_RULE"
		_:
			return str(code)

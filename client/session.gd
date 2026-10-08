class_name ClientSession
extends Node

## Thin client mirror. Sends intents and applies authoritative events.
## Optimistic overlay lives only in `pending` and is dropped on Reject or MatchEnd.
##
## Rendering reads this through view_tile / view_edges_in_block / summary. After each
## `updated` the view pulls take_dirty_blocks() for the 8×8 block keys whose data
## changed since the last pull; MATCH_START, WELCOME, MATCH_END and a faction change
## mark every block. `updated` keeps its zero-argument shape because smoke_client
## connects a zero-argument handler to it.
##
## The alert feed carries Reject (in player words, see reject_message), PowerAlert,
## CongestionAlert, and one local hint: the first confirmed zoning of a tile that no
## road touches says which tool lays one (ROAD_HINT, once per round).

signal updated
## Fired once per WELCOME, after faction and token are known.
signal welcomed(welcome: ServerWelcome)
## Fired for every command handed to the transport. The dev stub answers these.
signal command_sent(cmd: GameCommand)

const MAX_ALERTS := 5
## CongestionAlert at or above this value is listed in the HUD alert feed.
const ALERT_CONGESTION_MIN := 0.5
## Local hint after the first zoning of a tile without a road; %d,%d is the tile.
const ROAD_HINT := "No road at %d,%d · use tool 6 (Road)"

enum AlertKind { REJECT, POWER, CONGESTION, HINT }

var faction: int = SliceConstants.Owner.NEUTRAL
var match_started: bool = false
var match_start: MatchStart = null
var match_end: MatchEnd = null
var welcome: ServerWelcome = null
var faction_state: FactionState = null
var crisis: CrisisEvent = null
var last_reject: CommandReject = null
var rejects: Array[CommandReject] = []
var last_score: ScoreTick = null
## Newest last, at most MAX_ALERTS. {"kind": AlertKind, "time": "HH:MM:SS", "text": String}
var alerts: Array[Dictionary] = []

var _tiles: Dictionary = {}
var _edges: Dictionary = {}
var _summaries: Dictionary = {}
var _subscribed: Dictionary = {}
var _pending: Array[GameCommand] = []
var _dirty_blocks: Dictionary = {}
var _dirty_all: bool = false
var _road_hint_sent: bool = false


func _ready() -> void:
	# The pre-handshake host announces the faction with this signal; the handshake
	# server carries it in WELCOME. Connect dynamically so either GameNet shape loads.
	if GameNet.has_signal("faction_assigned"):
		GameNet.connect("faction_assigned", _on_faction)
	GameNet.event_received.connect(_on_event)


## Input is allowed once the faction is known and the round is running. The faction
## comes from WELCOME (handshake server) or faction_assigned (pre-handshake host).
func can_act() -> bool:
	return match_started and faction != SliceConstants.Owner.NEUTRAL


func send_command(cmd: GameCommand) -> void:
	if cmd == null:
		return
	_pending.append(cmd)
	_mark_dirty_command(cmd)
	GameNet.submit_local(cmd)
	command_sent.emit(cmd)
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


func summary(block_key: String) -> RegionSummary:
	if not _summaries.has(block_key):
		return null
	return _summaries[block_key]


func is_subscribed(block_key: String) -> bool:
	return _subscribed.has(block_key)


## Every authoritative tile the mirror holds (subscribed blocks only). Read-only use.
func authoritative_tiles() -> Array:
	return _tiles.values()


## Tile ids touched by an authoritative edge, as a set {id: true}.
func road_tile_ids() -> Dictionary:
	var ids: Dictionary = {}
	for key in _edges:
		var body: EdgeDelta = _edges[key]
		ids[SliceConstants.tile_id(body.a.x, body.a.y)] = true
		ids[SliceConstants.tile_id(body.b.x, body.b.y)] = true
	return ids


## True when an edge touches the tile. With include_pending the optimistic overlay
## counts (pending AddEdge adds, pending RemoveEdge hides), as the view draws it.
func has_road(x: int, y: int, include_pending: bool = true) -> bool:
	var cell := Vector2i(x, y)
	if include_pending:
		for edge in view_edges_in_block(InterestId.from_tile(x, y).key()):
			if edge.a == cell or edge.b == cell:
				return true
		return false
	for key in _edges:
		var body: EdgeDelta = _edges[key]
		if body.a == cell or body.b == cell:
			return true
	return false


## Authoritative tile with this client's pending commands laid over it.
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


## Authoritative edges touching the block plus pending AddEdge, minus pending RemoveEdge.
func view_edges_in_block(block_key: String) -> Array[EdgeDelta]:
	var merged: Dictionary = {}
	for key in _edges:
		var body: EdgeDelta = _edges[key]
		if _edge_touches_block(body.a, body.b, block_key):
			merged[key] = body
	for cmd in _pending:
		if cmd.kind != GameCommand.Kind.ADD_EDGE and cmd.kind != GameCommand.Kind.REMOVE_EDGE:
			continue
		if not _edge_touches_block(cmd.edge_a, cmd.edge_b, block_key):
			continue
		var key := WorldState.edge_key(cmd.edge_a, cmd.edge_b)
		if cmd.kind == GameCommand.Kind.REMOVE_EDGE:
			merged.erase(key)
		elif not merged.has(key):
			merged[key] = WorldState.ordered_edge(cmd.edge_a, cmd.edge_b)
	var result: Array[EdgeDelta] = []
	for key in merged:
		result.append(merged[key])
	return result


## Tax rate the HUD should show: the newest pending SET_TAX_RATE, else the faction state.
func view_tax_rate() -> float:
	for i in range(_pending.size() - 1, -1, -1):
		if _pending[i].kind == GameCommand.Kind.SET_TAX_RATE:
			return _pending[i].rate
	if faction_state != null:
		return faction_state.tax_rate
	return SliceConstants.TAX_RATE_DEFAULT


## Block keys ("bx,by") whose data changed since the last call, then clears the set.
## Returns every block after MATCH_START, WELCOME, MATCH_END, or a faction change.
func take_dirty_blocks() -> Array[String]:
	var keys: Array[String] = []
	if _dirty_all:
		keys = all_block_keys()
	else:
		for key in _dirty_blocks:
			keys.append(str(key))
	_dirty_all = false
	_dirty_blocks.clear()
	return keys


static func all_block_keys() -> Array[String]:
	var keys: Array[String] = []
	for by in SliceConstants.BLOCKS_PER_AXIS:
		for bx in SliceConstants.BLOCKS_PER_AXIS:
			keys.append(InterestId.new(bx, by).key())
	return keys


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
		reject_text = "%s %s" % [reason_name(last_reject.reason), last_reject.detail]
	var phase := "lobby"
	if match_end != null:
		phase = "ended %s" % match_end.reason
	elif match_started:
		phase = "play"
	return "GameCity  %s\nfaction %s  cursor %d,%d  view_owner %s zone %s\npending %d  reject %s" % [
		phase,
		faction_name(faction),
		cursor.x,
		cursor.y,
		faction_name(view.owner),
		zone_name(view.zone),
		_pending.size(),
		reject_text,
	]


func _on_faction(assigned: int) -> void:
	faction = assigned
	_dirty_all = true
	updated.emit()


func _on_event(event: ServerEvent) -> void:
	_apply(event)
	updated.emit()


func _apply(event: ServerEvent) -> void:
	match event.kind:
		ServerEvent.Kind.WELCOME:
			if event.welcome == null:
				return
			welcome = event.welcome
			faction = welcome.faction
			_dirty_all = true
			welcomed.emit(welcome)
		ServerEvent.Kind.MATCH_START:
			match_started = true
			match_start = event.match_start
			match_end = null
			crisis = null
			_tiles.clear()
			_edges.clear()
			_summaries.clear()
			_subscribed.clear()
			_pending.clear()
			rejects.clear()
			last_reject = null
			_road_hint_sent = false
			_dirty_all = true
		ServerEvent.Kind.MATCH_END:
			match_end = event.match_end
			match_started = false
			_pending.clear()
			_dirty_all = true
		ServerEvent.Kind.FACTION_STATE:
			if event.faction_state == null:
				return
			if faction != SliceConstants.Owner.NEUTRAL and event.faction_state.faction != faction:
				return
			faction_state = event.faction_state
			# The server does not ack SET_TAX_RATE on its own; the next FACTION_STATE
			# carrying the requested rate is the acknowledgement.
			_clear_pending_tax_rate(faction_state.tax_rate)
		ServerEvent.Kind.TILE_DELTA:
			if event.tile_delta == null:
				return
			var tile := TileDelta.from_dict(event.tile_delta.to_dict())
			_mark_dirty_tile(tile.x, tile.y)
			if not _block_open(tile.x, tile.y):
				_tiles.erase(tile.id)
				return
			_tiles[tile.id] = tile
			if _clear_pending_tile(tile.x, tile.y) and tile.zone != SliceConstants.Zone.NONE:
				_maybe_road_hint(tile)
		ServerEvent.Kind.EDGE_DELTA:
			if event.edge_delta == null:
				return
			var delta := event.edge_delta
			var key := WorldState.edge_key(delta.a, delta.b)
			_mark_dirty_edge(delta.a, delta.b)
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
			if event.reject.command != null:
				_mark_dirty_command(event.reject.command)
			_push_alert(AlertKind.REJECT, _reject_text(event.reject))
		ServerEvent.Kind.INTEREST_UPDATE:
			if event.interest_update == null:
				return
			_apply_interest(event.interest_update)
		ServerEvent.Kind.REGION_SUMMARY:
			if event.region_summary != null and event.region_summary.interest != null:
				var block_key := event.region_summary.interest.key()
				_summaries[block_key] = event.region_summary
				_dirty_blocks[block_key] = true
		ServerEvent.Kind.CONGESTION_ALERT:
			if event.congestion_alert == null:
				return
			var alert := event.congestion_alert
			var edge_key := WorldState.edge_key(alert.a, alert.b)
			if _edges.has(edge_key):
				_edges[edge_key].congestion = alert.congestion
				_mark_dirty_edge(alert.a, alert.b)
			if alert.congestion >= ALERT_CONGESTION_MIN:
				_push_alert(
					AlertKind.CONGESTION,
					"Congestion %d%% on %d,%d-%d,%d" % [
						roundi(alert.congestion * 100.0), alert.a.x, alert.a.y, alert.b.x, alert.b.y
					]
				)
		ServerEvent.Kind.POWER_ALERT:
			if event.power_alert == null:
				return
			var power := event.power_alert
			var id := SliceConstants.tile_id(power.x, power.y)
			if _tiles.has(id):
				_tiles[id].power_covered = power.power_covered
				_tiles[id].brownout = power.brownout
				_mark_dirty_tile(power.x, power.y)
			if power.brownout:
				_push_alert(AlertKind.POWER, "Brownout at %d,%d" % [power.x, power.y])
			elif power.shortage:
				_push_alert(AlertKind.POWER, "No power at %d,%d" % [power.x, power.y])
		ServerEvent.Kind.SCORE_TICK:
			last_score = event.score_tick
		ServerEvent.Kind.CRISIS_EVENT:
			crisis = event.crisis_event


## A subscription change also dirties the block's orthogonal neighbours: a seam edge
## is drawn by whichever side is subscribed, so the neighbour must redraw too.
func _apply_interest(update: InterestUpdate) -> void:
	for block in update.add:
		if block != null:
			_subscribed[block.key()] = true
			_mark_dirty_block_and_neighbours(block)
	for block in update.remove:
		if block != null:
			_subscribed.erase(block.key())
			_mark_dirty_block_and_neighbours(block)
	_forget_outside_subscription()


func _mark_dirty_block_and_neighbours(block: InterestId) -> void:
	_dirty_blocks[block.key()] = true
	for step in WorldState.ORTHOGONAL:
		var bx := block.block_x + step.x
		var by := block.block_y + step.y
		if bx < 0 or by < 0 or bx >= SliceConstants.BLOCKS_PER_AXIS or by >= SliceConstants.BLOCKS_PER_AXIS:
			continue
		_dirty_blocks[InterestId.new(bx, by).key()] = true


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


func _edge_touches_block(a: Vector2i, b: Vector2i, block_key: String) -> bool:
	return (
		InterestId.from_tile(a.x, a.y).key() == block_key
		or InterestId.from_tile(b.x, b.y).key() == block_key
	)


func _mark_dirty_tile(x: int, y: int) -> void:
	if SliceConstants.in_map(x, y):
		_dirty_blocks[InterestId.from_tile(x, y).key()] = true


func _mark_dirty_edge(a: Vector2i, b: Vector2i) -> void:
	_mark_dirty_tile(a.x, a.y)
	_mark_dirty_tile(b.x, b.y)


func _mark_dirty_command(cmd: GameCommand) -> void:
	match cmd.kind:
		GameCommand.Kind.ADD_EDGE, GameCommand.Kind.REMOVE_EDGE:
			_mark_dirty_edge(cmd.edge_a, cmd.edge_b)
		GameCommand.Kind.SET_TAX_RATE:
			pass
		_:
			_mark_dirty_tile(cmd.tile_x, cmd.tile_y)


## A repeat of a line already in the feed (same kind and text, e.g. the same congested
## edge reported again) moves it to the top with the new time instead of filling the
## five slots with copies.
func _push_alert(kind: AlertKind, text: String) -> void:
	for i in range(alerts.size() - 1, -1, -1):
		if int(alerts[i]["kind"]) == kind and str(alerts[i]["text"]) == text:
			alerts.remove_at(i)
	alerts.append({
		"kind": kind,
		"time": Time.get_time_string_from_system(),
		"text": text,
	})
	while alerts.size() > MAX_ALERTS:
		alerts.pop_front()


## The server confirmed a zoning of this tile (the pending SetZone was just cleared by
## its TileDelta). Said once per round, only when no authoritative edge touches the tile.
func _maybe_road_hint(tile: TileDelta) -> void:
	if _road_hint_sent or has_road(tile.x, tile.y, false):
		return
	_road_hint_sent = true
	_push_alert(AlertKind.HINT, ROAD_HINT % [tile.x, tile.y])


## Alert line for a Reject: the command and its target, then the reason in player words.
func _reject_text(reject: CommandReject) -> String:
	var target := ""
	var kind := reject.kind
	if reject.command != null:
		kind = reject.command.kind
		match reject.command.kind:
			GameCommand.Kind.ADD_EDGE, GameCommand.Kind.REMOVE_EDGE:
				target = " %d,%d-%d,%d" % [
					reject.command.edge_a.x, reject.command.edge_a.y,
					reject.command.edge_b.x, reject.command.edge_b.y,
				]
			GameCommand.Kind.SET_TAX_RATE:
				target = " %d%%" % roundi(reject.command.rate * 100.0)
			_:
				target = " %d,%d" % [reject.command.tile_x, reject.command.tile_y]
	return "%s%s: %s" % [command_name(kind), target, reject_message(reject)]


## Reason of a Reject in player words. NOT_NEUTRAL is split by the mirror's owner of the
## target tile; the server answers OPPONENT_IMMUTABLE before NOT_NEUTRAL for the other
## faction's tiles, so that code gets the same words. INSUFFICIENT_FUNDS carries the
## price as detail "cost_<n>". Other codes keep their name and detail.
func reject_message(reject: CommandReject) -> String:
	match reject.reason:
		ReasonCode.Id.NOT_NEUTRAL:
			var owner := SliceConstants.Owner.NEUTRAL
			if reject.command != null:
				var current := tile(reject.command.tile_x, reject.command.tile_y)
				if current != null:
					owner = current.owner
			if owner == faction and faction != SliceConstants.Owner.NEUTRAL:
				return "Already yours"
			if owner != SliceConstants.Owner.NEUTRAL:
				return "Owned by the other faction"
			return "Not a neutral tile"
		ReasonCode.Id.OPPONENT_IMMUTABLE:
			return "Owned by the other faction"
		ReasonCode.Id.NOT_ADJACENT:
			return "Claim tiles next to your territory"
		ReasonCode.Id.NOT_OWNER:
			return "Not your tile"
		ReasonCode.Id.EDGE_RULE:
			return "Roads need both ends on your tiles"
		ReasonCode.Id.INSUFFICIENT_FUNDS:
			var cost := reject_cost(reject.detail)
			if cost >= 0:
				return "Not enough treasury (cost %d)" % cost
			return "Not enough treasury"
		_:
			if reject.detail.is_empty():
				return reason_name(reject.reason)
			return "%s (%s)" % [reason_name(reject.reason), reject.detail]


## The n of a "cost_<n>" reject detail, or -1.
static func reject_cost(detail: String) -> int:
	if not detail.begins_with("cost_"):
		return -1
	var digits := detail.substr(5)
	if not digits.is_valid_int():
		return -1
	return int(digits)


## Drops the pending tile commands on (x, y). Returns true when one of them zoned the
## tile (SetZone with a zone), which is what the road hint listens for.
func _clear_pending_tile(x: int, y: int) -> bool:
	var kept: Array[GameCommand] = []
	var zoned := false
	for cmd in _pending:
		var tile_cmd := (
			cmd.kind == GameCommand.Kind.CLAIM_TILE
			or cmd.kind == GameCommand.Kind.SET_ZONE
			or cmd.kind == GameCommand.Kind.DEMOLISH_OWN
			or cmd.kind == GameCommand.Kind.PLACE_POWER
			or cmd.kind == GameCommand.Kind.REMOVE_POWER
		)
		if tile_cmd and cmd.tile_x == x and cmd.tile_y == y:
			if cmd.kind == GameCommand.Kind.SET_ZONE and cmd.zone != SliceConstants.Zone.NONE:
				zoned = true
			continue
		kept.append(cmd)
	_pending = kept
	return zoned


func _clear_pending_edge(a: Vector2i, b: Vector2i) -> void:
	var kept: Array[GameCommand] = []
	for cmd in _pending:
		var edge_cmd := cmd.kind == GameCommand.Kind.ADD_EDGE or cmd.kind == GameCommand.Kind.REMOVE_EDGE
		if edge_cmd and WorldState.same_edge(cmd.edge_a, cmd.edge_b, a, b):
			continue
		kept.append(cmd)
	_pending = kept


func _clear_pending_tax_rate(rate: float) -> void:
	var kept: Array[GameCommand] = []
	for cmd in _pending:
		if cmd.kind == GameCommand.Kind.SET_TAX_RATE and is_equal_approx(cmd.rate, rate):
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
	match a.kind:
		GameCommand.Kind.ADD_EDGE, GameCommand.Kind.REMOVE_EDGE:
			return WorldState.same_edge(a.edge_a, a.edge_b, b.edge_a, b.edge_b)
		GameCommand.Kind.SET_TAX_RATE:
			return is_equal_approx(a.rate, b.rate)
		_:
			return a.tile_x == b.tile_x and a.tile_y == b.tile_y and a.zone == b.zone


static func faction_name(owner: int) -> String:
	match owner:
		SliceConstants.Owner.FACTION_A:
			return "A"
		SliceConstants.Owner.FACTION_B:
			return "B"
		_:
			return "neutral"


static func zone_name(zone: int) -> String:
	match zone:
		SliceConstants.Zone.R:
			return "R"
		SliceConstants.Zone.C:
			return "C"
		SliceConstants.Zone.I:
			return "I"
		_:
			return "none"


static func command_name(kind: int) -> String:
	match kind:
		GameCommand.Kind.CLAIM_TILE:
			return "ClaimTile"
		GameCommand.Kind.SET_ZONE:
			return "SetZone"
		GameCommand.Kind.ADD_EDGE:
			return "AddEdge"
		GameCommand.Kind.REMOVE_EDGE:
			return "RemoveEdge"
		GameCommand.Kind.PLACE_POWER:
			return "PlacePower"
		GameCommand.Kind.REMOVE_POWER:
			return "RemovePower"
		GameCommand.Kind.DEMOLISH_OWN:
			return "DemolishOwn"
		GameCommand.Kind.SET_TAX_RATE:
			return "SetTaxRate"
		_:
			return "Command%d" % kind


static func reason_name(code: int) -> String:
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
		ReasonCode.Id.INSUFFICIENT_FUNDS:
			return "INSUFFICIENT_FUNDS"
		ReasonCode.Id.INVALID_RATE:
			return "INVALID_RATE"
		ReasonCode.Id.NOT_AUTHENTICATED:
			return "NOT_AUTHENTICATED"
		_:
			return str(code)

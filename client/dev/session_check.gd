extends Node

## Headless check of the ClientSession mirror without a server: feeds ServerEvents
## through GameNet.event_received and asserts pending rollback, the SET_TAX_RATE
## pending match, the new reason names, WELCOME / FACTION_STATE handling, the alert
## feed, and the dirty-block pull. Prints SESSION_OK and exits 0.
##   godot --headless --path . res://client/dev/session_check.tscn

var _failures: Array[String] = []
var session: ClientSession


func _ready() -> void:
	session = ClientSession.new()
	session.name = "Session"
	add_child(session)
	_run()
	if _failures.is_empty():
		print("SESSION_OK")
		get_tree().quit(0)
	else:
		for line in _failures:
			printerr("SESSION_FAIL " + line)
		get_tree().quit(1)


func _run() -> void:
	_check_identity()
	_check_welcome_and_faction_state()
	_check_tax_rate_pending()
	_check_reason_names()
	_check_optimistic_rollback()
	_check_edges_view()
	_check_alerts_and_crisis()
	_check_dirty_blocks()


func _check_identity() -> void:
	var path := "user://identity_check.cfg"
	var fresh := ClientIdentity.new(path)
	fresh.clear()
	_expect(not fresh.load(), "identity: missing file loads false")
	var generated := fresh.ensure_name("")
	_expect(generated.begins_with(ClientIdentity.NAME_PREFIX) and generated.length() == 11, "identity: generated name %s" % generated)
	_expect(fresh.ensure_name("alice") == "alice", "identity: preferred name wins")
	_expect(fresh.ensure_name("").length() == 5, "identity: empty preferred keeps stored")
	var long_name := "x".repeat(ClientHello.NAME_MAX + 5)
	_expect(fresh.ensure_name(long_name).length() == ClientHello.NAME_MAX, "identity: long name truncated")
	var hello := fresh.hello()
	_expect(hello.token.is_empty() and hello.protocol == SliceConstants.PROTOCOL_VERSION, "identity: first hello has empty token")
	var welcome := ServerWelcome.new()
	welcome.token = "tok-123"
	welcome.name = "alice"
	welcome.faction = SliceConstants.Owner.FACTION_B
	_expect(fresh.accept_welcome(welcome) == OK, "identity: accept_welcome saves")
	var again := ClientIdentity.new(path)
	_expect(again.load(), "identity: file loads after save")
	_expect(again.token == "tok-123" and again.name == "alice", "identity: token and name round trip")
	_expect(again.hello().token == "tok-123", "identity: reconnect hello carries token")
	again.clear()
	_expect(not ClientIdentity.new(path).load(), "identity: clear removes file")


func _check_welcome_and_faction_state() -> void:
	var seen: Array = []
	session.welcomed.connect(func(w: ServerWelcome) -> void: seen.append(w))
	var welcome := ServerWelcome.new()
	welcome.token = "tok"
	welcome.faction = SliceConstants.Owner.FACTION_B
	welcome.player_id = 7
	_emit(ServerEvent.with_welcome(welcome))
	_expect(session.faction == SliceConstants.Owner.FACTION_B, "welcome sets faction")
	_expect(session.welcome != null and session.welcome.player_id == 7, "welcome stored")
	_expect(seen.size() == 1, "welcomed signal fired once")
	_expect(not session.can_act(), "cannot act before MATCH_START")
	_emit(ServerEvent.with_match_start(MatchStart.new()))
	_expect(session.can_act(), "can act after WELCOME + MATCH_START")
	var other := FactionState.new()
	other.faction = SliceConstants.Owner.FACTION_A
	other.treasury = 1.0
	_emit(ServerEvent.with_faction_state(other))
	_expect(session.faction_state == null, "other faction's state ignored")
	var mine := FactionState.new()
	mine.faction = SliceConstants.Owner.FACTION_B
	mine.treasury = 4321.0
	mine.tax_rate = 0.10
	_emit(ServerEvent.with_faction_state(mine))
	_expect(session.faction_state != null and is_equal_approx(session.faction_state.treasury, 4321.0), "own faction state stored")


func _check_tax_rate_pending() -> void:
	session.send_command(GameCommand.set_tax_rate(0.20))
	session.send_command(GameCommand.set_tax_rate(0.25))
	_expect(session.pending_count() == 2, "two tax pendings")
	_expect(is_equal_approx(session.view_tax_rate(), 0.25), "view_tax_rate shows newest pending")
	var reject := CommandReject.new(GameCommand.set_tax_rate(0.25), ReasonCode.Id.INVALID_RATE, "")
	_emit(ServerEvent.with_reject(reject))
	_expect(session.pending_count() == 1, "reject of 0.25 removes only that pending (got %d)" % session.pending_count())
	_expect(is_equal_approx(session.view_tax_rate(), 0.20), "0.20 pending survives the reject of 0.25")
	var state := FactionState.new()
	state.faction = SliceConstants.Owner.FACTION_B
	state.tax_rate = 0.20
	_emit(ServerEvent.with_faction_state(state))
	_expect(session.pending_count() == 0, "FACTION_STATE with the requested rate acks the pending")
	_expect(is_equal_approx(session.view_tax_rate(), 0.20), "view_tax_rate falls back to faction state")


func _check_reason_names() -> void:
	_expect(ClientSession.reason_name(ReasonCode.Id.INSUFFICIENT_FUNDS) == "INSUFFICIENT_FUNDS", "reason INSUFFICIENT_FUNDS")
	_expect(ClientSession.reason_name(ReasonCode.Id.INVALID_RATE) == "INVALID_RATE", "reason INVALID_RATE")
	_expect(ClientSession.reason_name(ReasonCode.Id.NOT_AUTHENTICATED) == "NOT_AUTHENTICATED", "reason NOT_AUTHENTICATED")
	_expect(ClientSession.command_name(GameCommand.Kind.SET_TAX_RATE) == "SetTaxRate", "command name SetTaxRate")


func _check_optimistic_rollback() -> void:
	var update := InterestUpdate.new()
	update.add.append(InterestId.new(0, 0))
	_emit(ServerEvent.with_interest_update(update))
	var neutral := TileDelta.from_cell(3, 3)
	_emit(ServerEvent.with_tile_delta(neutral))
	session.send_command(GameCommand.claim_tile(3, 3))
	_expect(session.view_tile(3, 3).owner == SliceConstants.Owner.FACTION_B, "optimistic claim shows own faction")
	var reject := CommandReject.new(GameCommand.claim_tile(3, 3), ReasonCode.Id.NOT_ADJACENT, "not_adjacent")
	_emit(ServerEvent.with_reject(reject))
	_expect(session.view_tile(3, 3).owner == SliceConstants.Owner.NEUTRAL, "reject rolls the claim back")
	_expect(session.pending_count() == 0, "pending empty after reject")
	_expect(session.saw_reject(ReasonCode.Id.NOT_ADJACENT, GameCommand.Kind.CLAIM_TILE, Vector2i(3, 3)), "saw_reject finds it")
	session.send_command(GameCommand.set_zone(3, 3, SliceConstants.Zone.C))
	var authoritative := TileDelta.from_cell(3, 3)
	authoritative.owner = SliceConstants.Owner.FACTION_B
	authoritative.zone = SliceConstants.Zone.C
	authoritative.has_building = true
	_emit(ServerEvent.with_tile_delta(authoritative))
	_expect(session.pending_count() == 0, "tile delta acks the zone pending")
	_expect(session.view_tile(3, 3).zone == SliceConstants.Zone.C, "authoritative zone visible")
	var outside := TileDelta.from_cell(40, 40)
	_emit(ServerEvent.with_tile_delta(outside))
	_expect(session.tile(40, 40) == null, "tile outside subscription is dropped")


func _check_edges_view() -> void:
	session.send_command(GameCommand.add_edge(Vector2i(3, 3), Vector2i(4, 3)))
	var pending_edges := session.view_edges_in_block("0,0")
	_expect(pending_edges.size() == 1, "pending AddEdge visible in block view (got %d)" % pending_edges.size())
	var delta := WorldState.ordered_edge(Vector2i(3, 3), Vector2i(4, 3))
	delta.capacity = WorldState.EDGE_CAPACITY
	_emit(ServerEvent.with_edge_delta(delta))
	_expect(session.pending_count() == 0, "edge delta acks the AddEdge pending")
	_expect(session.edge(Vector2i(4, 3), Vector2i(3, 3)) != null, "edge stored under ordered key")
	session.send_command(GameCommand.remove_edge(Vector2i(4, 3), Vector2i(3, 3)))
	_expect(session.view_edges_in_block("0,0").is_empty(), "pending RemoveEdge hides the edge")
	_emit(ServerEvent.with_edge_delta(EdgeDelta.make_removed(Vector2i(3, 3), Vector2i(4, 3))))
	_expect(session.edge(Vector2i(3, 3), Vector2i(4, 3)) == null, "removed edge gone")
	_expect(session.pending_count() == 0, "removal acks pending")
	var cross := WorldState.ordered_edge(Vector2i(7, 2), Vector2i(8, 2))
	_emit(ServerEvent.with_edge_delta(cross))
	_expect(session.view_edges_in_block("0,0").size() == 1, "edge crossing into block 1,0 listed for 0,0")
	_expect(session.view_edges_in_block("1,0").size() == 1, "and listed for 1,0")


func _check_alerts_and_crisis() -> void:
	var before := session.alerts.size()
	var congestion := CongestionAlert.new()
	congestion.a = Vector2i(7, 2)
	congestion.b = Vector2i(8, 2)
	congestion.congestion = 0.9
	_emit(ServerEvent.with_congestion_alert(congestion))
	_expect(session.alerts.size() == before + 1, "congestion >= threshold adds an alert")
	_expect(is_equal_approx(session.edge(Vector2i(7, 2), Vector2i(8, 2)).congestion, 0.9), "congestion value stored on edge")
	var mild := CongestionAlert.new()
	mild.a = Vector2i(7, 2)
	mild.b = Vector2i(8, 2)
	mild.congestion = 0.2
	_emit(ServerEvent.with_congestion_alert(mild))
	_expect(session.alerts.size() == before + 1, "mild congestion is not listed")
	var power := PowerAlert.new()
	power.x = 3
	power.y = 3
	power.power_covered = true
	power.brownout = true
	_emit(ServerEvent.with_power_alert(power))
	_expect(session.tile(3, 3).brownout, "power alert writes brownout")
	_expect(session.alerts.back()["text"].begins_with("Brownout"), "brownout alert text")
	for i in 10:
		var reject := CommandReject.new(GameCommand.claim_tile(i, 0), ReasonCode.Id.INSUFFICIENT_FUNDS, "")
		_emit(ServerEvent.with_reject(reject))
	_expect(session.alerts.size() == ClientSession.MAX_ALERTS, "alert feed capped at %d" % ClientSession.MAX_ALERTS)
	_expect(session.alerts.back()["text"].find("INSUFFICIENT_FUNDS") != -1, "reject alert names the reason")
	_expect(str(session.alerts.back()["time"]).length() == 8, "alert carries HH:MM:SS")
	var crisis := CrisisEvent.new()
	crisis.kind = CrisisEvent.KIND_GRID_STORM
	crisis.active = true
	_emit(ServerEvent.with_crisis_event(crisis))
	_expect(session.crisis != null and session.crisis.active, "crisis stored")
	var tick := ScoreTick.new()
	tick.seconds_remaining = 90061
	_emit(ServerEvent.with_score_tick(tick))
	_expect(session.last_score != null and session.last_score.seconds_remaining == 90061, "score tick stored")


func _check_dirty_blocks() -> void:
	session.take_dirty_blocks()
	_expect(session.take_dirty_blocks().is_empty(), "dirty set empty after pull")
	_emit(ServerEvent.with_tile_delta(TileDelta.from_cell(5, 5)))
	var keys := session.take_dirty_blocks()
	_expect(keys.size() == 1 and keys[0] == "0,0", "tile delta dirties its block only (got %s)" % str(keys))
	var cross := WorldState.ordered_edge(Vector2i(7, 5), Vector2i(8, 5))
	_emit(ServerEvent.with_edge_delta(cross))
	keys = session.take_dirty_blocks()
	keys.sort()
	_expect(keys == (["0,0", "1,0"] as Array[String]), "cross-block edge dirties both blocks (got %s)" % str(keys))
	var summary := RegionSummary.new()
	summary.interest = InterestId.new(9, 9)
	summary.population = 3
	_emit(ServerEvent.with_region_summary(summary))
	keys = session.take_dirty_blocks()
	_expect(keys == (["9,9"] as Array[String]), "summary dirties its block")
	_expect(session.summary("9,9") != null and session.summary("9,9").population == 3, "summary stored")
	session.send_command(GameCommand.set_tax_rate(0.1))
	_expect(session.take_dirty_blocks().is_empty(), "tax rate dirties nothing")
	_emit(ServerEvent.with_match_start(MatchStart.new()))
	var all := session.take_dirty_blocks()
	_expect(all.size() == SliceConstants.BLOCKS_PER_AXIS * SliceConstants.BLOCKS_PER_AXIS, "MATCH_START dirties every block")
	_expect(session.pending_count() == 0, "MATCH_START clears pending")
	var end := MatchEnd.new()
	end.reason = MatchEnd.REASON_CLOCK
	_emit(ServerEvent.with_match_end(end))
	_expect(not session.can_act(), "cannot act after MATCH_END")


func _emit(event: ServerEvent) -> void:
	# Round-trip through the wire dictionary, as server_events_rpc does.
	GameNet.event_received.emit(ServerEvent.from_dict(event.to_dict()))


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)

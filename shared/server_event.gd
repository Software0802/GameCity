class_name ServerEvent
extends RefCounted

## Server → client envelope. Kind values match docs/briefs/netcode-interface-v0.md.
## Exactly one payload field is set for a given kind. No simulation here.
## New kinds are appended so existing wire ints stay stable.

enum Kind {
	MATCH_START,
	TILE_DELTA,
	EDGE_DELTA,
	POWER_ALERT,
	CONGESTION_ALERT,
	CRISIS_EVENT,
	SCORE_TICK,
	MATCH_END,
	REJECT,
	INTEREST_UPDATE,
	REGION_SUMMARY,
	WELCOME,
	FACTION_STATE,
}

var kind: Kind = Kind.MATCH_START
var match_start: MatchStart = null
var tile_delta: TileDelta = null
var edge_delta: EdgeDelta = null
var power_alert: PowerAlert = null
var congestion_alert: CongestionAlert = null
var crisis_event: CrisisEvent = null
var score_tick: ScoreTick = null
var match_end: MatchEnd = null
var reject: CommandReject = null
var interest_update: InterestUpdate = null
var region_summary: RegionSummary = null
var welcome: ServerWelcome = null
var faction_state: FactionState = null


static func with_match_start(body: MatchStart) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.MATCH_START
	event.match_start = body
	return event


static func with_tile_delta(body: TileDelta) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.TILE_DELTA
	event.tile_delta = body
	return event


static func with_edge_delta(body: EdgeDelta) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.EDGE_DELTA
	event.edge_delta = body
	return event


static func with_power_alert(body: PowerAlert) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.POWER_ALERT
	event.power_alert = body
	return event


static func with_congestion_alert(body: CongestionAlert) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.CONGESTION_ALERT
	event.congestion_alert = body
	return event


static func with_crisis_event(body: CrisisEvent) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.CRISIS_EVENT
	event.crisis_event = body
	return event


static func with_score_tick(body: ScoreTick) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.SCORE_TICK
	event.score_tick = body
	return event


static func with_match_end(body: MatchEnd) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.MATCH_END
	event.match_end = body
	return event


static func with_reject(body: CommandReject) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.REJECT
	event.reject = body
	return event


static func with_interest_update(body: InterestUpdate) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.INTEREST_UPDATE
	event.interest_update = body
	return event


static func with_region_summary(body: RegionSummary) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.REGION_SUMMARY
	event.region_summary = body
	return event


static func with_welcome(body: ServerWelcome) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.WELCOME
	event.welcome = body
	return event


static func with_faction_state(body: FactionState) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = Kind.FACTION_STATE
	event.faction_state = body
	return event


func to_dict() -> Dictionary:
	var data := {"kind": int(kind)}
	match kind:
		Kind.MATCH_START:
			if match_start != null:
				data["match_start"] = match_start.to_dict()
		Kind.TILE_DELTA:
			if tile_delta != null:
				data["tile_delta"] = tile_delta.to_dict()
		Kind.EDGE_DELTA:
			if edge_delta != null:
				data["edge_delta"] = edge_delta.to_dict()
		Kind.POWER_ALERT:
			if power_alert != null:
				data["power_alert"] = power_alert.to_dict()
		Kind.CONGESTION_ALERT:
			if congestion_alert != null:
				data["congestion_alert"] = congestion_alert.to_dict()
		Kind.CRISIS_EVENT:
			if crisis_event != null:
				data["crisis_event"] = crisis_event.to_dict()
		Kind.SCORE_TICK:
			if score_tick != null:
				data["score_tick"] = score_tick.to_dict()
		Kind.MATCH_END:
			if match_end != null:
				data["match_end"] = match_end.to_dict()
		Kind.REJECT:
			if reject != null:
				data["reject"] = reject.to_dict()
		Kind.INTEREST_UPDATE:
			if interest_update != null:
				data["interest_update"] = interest_update.to_dict()
		Kind.REGION_SUMMARY:
			if region_summary != null:
				data["region_summary"] = region_summary.to_dict()
		Kind.WELCOME:
			if welcome != null:
				data["welcome"] = welcome.to_dict()
		Kind.FACTION_STATE:
			if faction_state != null:
				data["faction_state"] = faction_state.to_dict()
	return data


static func from_dict(data: Dictionary) -> ServerEvent:
	var event := ServerEvent.new()
	event.kind = int(data.get("kind", Kind.MATCH_START))
	match event.kind:
		Kind.MATCH_START:
			if data.get("match_start") is Dictionary:
				event.match_start = MatchStart.from_dict(data["match_start"])
		Kind.TILE_DELTA:
			if data.get("tile_delta") is Dictionary:
				event.tile_delta = TileDelta.from_dict(data["tile_delta"])
		Kind.EDGE_DELTA:
			if data.get("edge_delta") is Dictionary:
				event.edge_delta = EdgeDelta.from_dict(data["edge_delta"])
		Kind.POWER_ALERT:
			if data.get("power_alert") is Dictionary:
				event.power_alert = PowerAlert.from_dict(data["power_alert"])
		Kind.CONGESTION_ALERT:
			if data.get("congestion_alert") is Dictionary:
				event.congestion_alert = CongestionAlert.from_dict(data["congestion_alert"])
		Kind.CRISIS_EVENT:
			if data.get("crisis_event") is Dictionary:
				event.crisis_event = CrisisEvent.from_dict(data["crisis_event"])
		Kind.SCORE_TICK:
			if data.get("score_tick") is Dictionary:
				event.score_tick = ScoreTick.from_dict(data["score_tick"])
		Kind.MATCH_END:
			if data.get("match_end") is Dictionary:
				event.match_end = MatchEnd.from_dict(data["match_end"])
		Kind.REJECT:
			if data.get("reject") is Dictionary:
				event.reject = CommandReject.from_dict(data["reject"])
		Kind.INTEREST_UPDATE:
			if data.get("interest_update") is Dictionary:
				event.interest_update = InterestUpdate.from_dict(data["interest_update"])
		Kind.REGION_SUMMARY:
			if data.get("region_summary") is Dictionary:
				event.region_summary = RegionSummary.from_dict(data["region_summary"])
		Kind.WELCOME:
			if data.get("welcome") is Dictionary:
				event.welcome = ServerWelcome.from_dict(data["welcome"])
		Kind.FACTION_STATE:
			if data.get("faction_state") is Dictionary:
				event.faction_state = FactionState.from_dict(data["faction_state"])
	return event

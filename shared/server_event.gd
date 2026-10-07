class_name ServerEvent
extends RefCounted

## Server → client message kinds from docs/briefs/netcode-interface-v0.md.
## Payloads (alerts, score, crisis) are named here only. No simulation yet.

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
}

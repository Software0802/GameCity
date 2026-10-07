class_name ReasonCode
extends RefCounted

## Reject.reason values. NOT_IMPLEMENTED is the skeleton default.
## Rule names match docs/briefs/world-vertical-slice.md.

enum Id {
	OK,
	NOT_IMPLEMENTED,
	UNKNOWN_COMMAND,
	MATCH_NOT_ACTIVE,
	OUT_OF_BOUNDS,
	NOT_NEUTRAL,
	NOT_ADJACENT,
	NOT_OWNER,
	OPPONENT_IMMUTABLE,
	INVALID_ZONE,
	NOT_ORTHOGONAL,
	EDGE_RULE,
}

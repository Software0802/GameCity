class_name ReasonCode
extends RefCounted

## Reject.reason values. Names match docs/briefs/world-vertical-slice.md and
## docs/plans/m2-city-phase.md. In-match rules return a specific code.
## NOT_IMPLEMENTED stays in the enum. New codes are appended so wire ints stay stable.

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
	## Treasury cannot cover the command's cost. State unchanged.
	INSUFFICIENT_FUNDS,
	## SET_TAX_RATE outside [TAX_RATE_MIN, TAX_RATE_MAX].
	INVALID_RATE,
	## Command arrived before the connection's WELCOME.
	NOT_AUTHENTICATED,
}

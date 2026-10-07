class_name SliceConstants
extends RefCounted

## Locked vertical-slice numbers. Prose lives in docs/briefs/.
## This script is pure data: it does not extend Node.

const MAP_SIZE := 64
const INTEREST_BLOCK := 8
const BLOCKS_PER_AXIS := MAP_SIZE / INTEREST_BLOCK
const SIM_TICK_SEC := 1.0

## Suggested in the world brief. Not a tuned gameplay value.
const POWER_RADIUS_SUGGESTED := 4

const FACTION_COUNT := 2
const PLAYERS_MIN := 2
const PLAYERS_MAX := 4
const MATCH_MINUTES_MIN := 30
const MATCH_MINUTES_MAX := 45

const SCORE_WEIGHT_POP := 0.40
const SCORE_WEIGHT_FISCAL := 0.30
const SCORE_WEIGHT_CONTROL := 0.30

const BUILDING_TIER_MIN := 0
const BUILDING_TIER_MAX := 2

enum Owner {
	NEUTRAL = -1,
	FACTION_A = 0,
	FACTION_B = 1,
}

enum Zone {
	NONE,
	R,
	C,
	I,
}

static func tile_id(x: int, y: int) -> int:
	return y * MAP_SIZE + x

static func in_map(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < MAP_SIZE and y < MAP_SIZE


## True for R, C, I, and none. Any other int is not a zone.
static func is_zone(zone: int) -> bool:
	return zone == Zone.NONE or zone == Zone.R or zone == Zone.C or zone == Zone.I

class_name SliceConstants
extends RefCounted

## Locked numbers for the M2 city phase. Prose lives in docs/briefs/design-v2.md
## and docs/plans/m2-city-phase.md. This script is pure data: it does not extend Node.
## Economy, growth, and crisis values are placeholders until sim-economy tunes them.

const MAP_SIZE := 128
const INTEREST_BLOCK := 8
const BLOCKS_PER_AXIS := MAP_SIZE / INTEREST_BLOCK
const SIM_TICK_SEC := 1.0

## Round clock. Wall-clock seconds; --round-seconds and --pace override at launch.
const ROUND_SECONDS_DEFAULT := 604800
const ROUND_SECONDS_TEST := 3600
const PACE_DEFAULT := 1.0

## Bump SAVE_FORMAT_VERSION when the save envelope or WorldState.to_save_dict() changes shape.
## Bump PROTOCOL_VERSION when a wire payload changes; ClientHello carries it.
const SAVE_FORMAT_VERSION := 1
const PROTOCOL_VERSION := 1

## Continuous tile fields are quantized to 1/FIELD_QUANT; an event fires only when
## the quantized value crosses a step.
const FIELD_QUANT := 8

## Economy placeholders.
const START_TREASURY := 5000
const COST_CLAIM_BASE := 50
## Each tile already owned adds this fraction to the next claim price.
const COST_CLAIM_GROWTH := 0.01
const COST_EDGE := 20
const COST_POWER := 400
const UPKEEP_POWER_PER_SEC := 0.5
const TAX_RATE_DEFAULT := 0.10
const TAX_RATE_MIN := 0.0
const TAX_RATE_MAX := 0.30
const INCOME_PER_POP_PER_SEC := 0.02
const INCOME_PER_JOB_PER_SEC := 0.01

## Growth placeholders.
const POWER_RADIUS := 4
const POWER_PLANT_CAPACITY := 20
const TIER_UP_SECONDS := 120
const TIER_DOWN_SECONDS := 180
const SAT_UP := 0.7
const SAT_DOWN := 0.3
## Satisfaction factor while the faction's demand for a tile's zone is not positive.
const DEMAND_GATE_CLOSED := 0.3
## Indexed by building tier 0–2.
const TIER_POP: Array[int] = [1, 3, 8]
const TIER_JOBS: Array[int] = [2, 6, 16]
const POLLUTION_RADIUS := 3
const CONGESTION_CAPACITY := 10

## The one shared mid-round crisis (grid storm).
const CRISIS_AT_FRACTION := 0.5
const CRISIS_DURATION_SEC := 90
const CRISIS_CAPACITY_FACTOR := 0.5

const FACTION_COUNT := 2
const PLAYERS_MIN := 2
const PLAYERS_MAX := 4

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

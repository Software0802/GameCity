extends RefCounted

## Per-faction ledgers: treasury, tax rate, and the running counters (owned
## tiles, population, jobs, plants) that income, costs, and the demand triangle
## read. WorldState keeps the counters current by calling add_building /
## add_owned / add_plant at every structural change, so nothing here scans the map.
##
## Pace: a tick is SIM_TICK_SEC of wall time but SIM_TICK_SEC / pace of sim time
## (design-v2: every growth and economy duration is base × pace). Income per tick is
## therefore the per-sim-second rate × (SIM_TICK_SEC / pace): the money earned over
## one tier-up cycle does not depend on pace.

class Ledger:
	extends RefCounted

	var treasury: float = float(SliceConstants.START_TREASURY)
	var tax_rate: float = SliceConstants.TAX_RATE_DEFAULT
	var owned: int = 0
	var population: int = 0
	var jobs_c: int = 0
	var jobs_i: int = 0
	var plants: int = 0

	func jobs() -> int:
		return jobs_c + jobs_i


var _ledgers: Array[Ledger] = []


func _init() -> void:
	for _faction in SliceConstants.FACTION_COUNT:
		_ledgers.append(Ledger.new())


static func is_faction(faction: int) -> bool:
	return faction >= 0 and faction < SliceConstants.FACTION_COUNT


func ledger(faction: int) -> Ledger:
	return _ledgers[faction]


## ClaimTile price: COST_CLAIM_BASE × (1 + tiles already owned × COST_CLAIM_GROWTH).
## The spawn block counts as owned, so faction A's first claim already costs more
## than the base price.
func claim_cost(faction: int) -> float:
	var owned := _ledgers[faction].owned
	return float(SliceConstants.COST_CLAIM_BASE) * (1.0 + float(owned) * SliceConstants.COST_CLAIM_GROWTH)


## True when the faction can pay (or free is set); the cost is deducted at once.
## False leaves the treasury untouched. The treasury may already be negative from
## upkeep; there is no bankruptcy rule, it only blocks further spending.
func charge(faction: int, cost: float, free: bool) -> bool:
	if free or cost <= 0.0:
		return true
	var book := _ledgers[faction]
	if book.treasury < cost:
		return false
	book.treasury -= cost
	return true


## Per-sim-second rate before pace: population × tax × INCOME_PER_POP_PER_SEC
## + jobs × INCOME_PER_JOB_PER_SEC − plants × UPKEEP_POWER_PER_SEC.
func base_rate(faction: int) -> float:
	var book := _ledgers[faction]
	return (
		float(book.population) * book.tax_rate * SliceConstants.INCOME_PER_POP_PER_SEC
		+ float(book.jobs()) * SliceConstants.INCOME_PER_JOB_PER_SEC
		- float(book.plants) * SliceConstants.UPKEEP_POWER_PER_SEC
	)


## Treasury change per wall-clock second at this pace. This is what the HUD shows.
func income_per_sec(faction: int, pace: float) -> float:
	return base_rate(faction) / pace


## One sim tick: every treasury moves by income_per_sec × SIM_TICK_SEC.
func tick(pace: float) -> void:
	for faction in _ledgers.size():
		_ledgers[faction].treasury += income_per_sec(faction, pace) * SliceConstants.SIM_TICK_SEC


func add_owned(faction: int, delta: int) -> void:
	_ledgers[faction].owned += delta


func add_plant(faction: int, delta: int) -> void:
	_ledgers[faction].plants += delta


## Population or job contribution of one building: R adds TIER_POP[tier],
## C and I add TIER_JOBS[tier] to their own job pool. sign is +1 or -1.
func add_building(faction: int, zone: int, tier: int, sign: int) -> void:
	if not is_faction(faction):
		return
	var book := _ledgers[faction]
	match zone:
		SliceConstants.Zone.R:
			book.population += sign * SliceConstants.TIER_POP[tier]
		SliceConstants.Zone.C:
			book.jobs_c += sign * SliceConstants.TIER_JOBS[tier]
		SliceConstants.Zone.I:
			book.jobs_i += sign * SliceConstants.TIER_JOBS[tier]


## Demand triangle, each in −1..1. R wants jobs it cannot fill; C and I want
## population their own job pool cannot employ.
func demand_r(faction: int) -> float:
	var book := _ledgers[faction]
	return _balance(book.jobs(), book.population)


func demand_c(faction: int) -> float:
	var book := _ledgers[faction]
	return _balance(book.population, book.jobs_c)


func demand_i(faction: int) -> float:
	var book := _ledgers[faction]
	return _balance(book.population, book.jobs_i)


## Demand for the zone a tile has; 0 for Zone.NONE.
func demand_for_zone(faction: int, zone: int) -> float:
	match zone:
		SliceConstants.Zone.R:
			return demand_r(faction)
		SliceConstants.Zone.C:
			return demand_c(faction)
		SliceConstants.Zone.I:
			return demand_i(faction)
	return 0.0


## (want − have) / (want + have), 0 when both are 0.
static func _balance(want: int, have: int) -> float:
	var total := want + have
	if total <= 0:
		return 0.0
	return float(want - have) / float(total)


## Save rows, faction order. Counters are not stored: WorldState rebuilds them
## from the tiles.
func to_rows() -> Array:
	var rows: Array = []
	for faction in _ledgers.size():
		var book := _ledgers[faction]
		rows.append({
			"faction": faction,
			"treasury": float(book.treasury),
			"tax_rate": float(book.tax_rate),
		})
	return rows


func restore_rows(raw) -> void:
	if not (raw is Array):
		return
	for row in raw:
		if not (row is Dictionary):
			continue
		var faction := int(row.get("faction", -1))
		if not is_faction(faction):
			push_warning("SimEconomy.restore_rows: faction %d unknown, skipped" % faction)
			continue
		var book := _ledgers[faction]
		book.treasury = float(row.get("treasury", SliceConstants.START_TREASURY))
		var rate := float(row.get("tax_rate", SliceConstants.TAX_RATE_DEFAULT))
		if GameCommand.is_valid_rate(rate):
			book.tax_rate = rate
		else:
			push_warning("SimEconomy.restore_rows: tax rate %s invalid, default kept" % rate)

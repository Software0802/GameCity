class_name FactionState
extends RefCounted

## One faction's economy snapshot, sent as ServerEvent.Kind.FACTION_STATE.
## Delivered only to players of that faction. It is neither a global event nor
## routed by interest region. technicians is always 0 in M2.

## SliceConstants.Owner. FACTION_A or FACTION_B.
var faction: int = SliceConstants.Owner.FACTION_A
var treasury: float = 0.0
var income_per_sec: float = 0.0
var population: int = 0
var jobs: int = 0
var technicians: int = 0
var tax_rate: float = SliceConstants.TAX_RATE_DEFAULT
## Demand triangle, each in −1..1.
var demand_r: float = 0.0
var demand_c: float = 0.0
var demand_i: float = 0.0
var power_capacity: int = 0
var power_load: int = 0


func to_dict() -> Dictionary:
	return {
		"faction": faction,
		"treasury": treasury,
		"income_per_sec": income_per_sec,
		"population": population,
		"jobs": jobs,
		"technicians": technicians,
		"tax_rate": tax_rate,
		"demand_r": demand_r,
		"demand_c": demand_c,
		"demand_i": demand_i,
		"power_capacity": power_capacity,
		"power_load": power_load,
	}


static func from_dict(data: Dictionary) -> FactionState:
	var state := FactionState.new()
	state.faction = int(data.get("faction", SliceConstants.Owner.FACTION_A))
	state.treasury = float(data.get("treasury", 0.0))
	state.income_per_sec = float(data.get("income_per_sec", 0.0))
	state.population = int(data.get("population", 0))
	state.jobs = int(data.get("jobs", 0))
	state.technicians = int(data.get("technicians", 0))
	state.tax_rate = float(data.get("tax_rate", SliceConstants.TAX_RATE_DEFAULT))
	state.demand_r = float(data.get("demand_r", 0.0))
	state.demand_c = float(data.get("demand_c", 0.0))
	state.demand_i = float(data.get("demand_i", 0.0))
	state.power_capacity = int(data.get("power_capacity", 0))
	state.power_load = int(data.get("power_load", 0))
	return state

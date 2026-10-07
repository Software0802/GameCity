extends RefCounted

## Satisfaction and tier growth for every zoned building, one pass per tick.
##
## satisfaction = has_road × powered × demand gate × (1 − congestion) × (1 − pollution)
##                × tax penalty
##   has_road, powered  0 or 1 (powered = power_covered and not brownout)
##   demand gate        1 when the faction's demand for this zone is > 0, else
##                      DEMAND_GATE_CLOSED
##   congestion         mean quantized congestion of the tile's incident edges
##   pollution          the pollution field value, 0–1
##   tax penalty        1 − tax_rate (linear: 0.9 at the default rate, 0.7 at the cap)
##
## A tile at or above SAT_UP accumulates sim seconds toward TIER_UP_SECONDS and
## then rises one tier; at or below SAT_DOWN it accumulates toward TIER_DOWN_SECONDS
## and falls one tier; in between the timer resets. One signed timer per tile
## (positive = toward up, negative = toward down) is what the save stores. Each tick
## adds SIM_TICK_SEC / pace sim seconds, so a tier step takes TIER_UP_SECONDS × pace
## wall seconds (design-v2: durations are base × pace).
##
## run() takes copy-on-write views of the per-tile arrays and touches no objects;
## WorldState applies the tier changes it returns.

## Float slack on the SAT_UP / SAT_DOWN comparisons.
const EPS := 1e-6

var _timer: PackedFloat32Array = PackedFloat32Array()
var _sat_raw: PackedFloat32Array = PackedFloat32Array()
var _sat_q: PackedFloat32Array = PackedFloat32Array()


func _init() -> void:
	var count := SliceConstants.MAP_SIZE * SliceConstants.MAP_SIZE
	_timer.resize(count)
	_timer.fill(0.0)
	_sat_raw.resize(count)
	_sat_raw.fill(0.0)
	_sat_q.resize(count)
	_sat_q.fill(0.0)


static func gate_for(demand: float) -> float:
	return 1.0 if demand > 0.0 else SliceConstants.DEMAND_GATE_CLOSED


static func tax_penalty(tax_rate: float) -> float:
	return 1.0 - tax_rate


## Sim seconds one tick advances at this pace.
static func sim_seconds_per_tick(pace: float) -> float:
	return SliceConstants.SIM_TICK_SEC / pace


## One pass over the active tiles. gates[faction] is a PackedFloat32Array indexed by
## zone; penalties[faction] is the tax penalty. Returns
## {"sat_changed": PackedInt32Array of tiles whose quantized satisfaction moved,
##  "tier_changes": [[id, new_tier], ...]}.
func run(
	active: PackedInt32Array,
	owner: PackedInt32Array,
	zone: PackedInt32Array,
	tier: PackedInt32Array,
	degree: PackedInt32Array,
	cover: PackedInt32Array,
	dark: PackedInt32Array,
	tile_congestion: PackedFloat32Array,
	mass: PackedInt32Array,
	mass_total: int,
	gates: Array,
	penalties: PackedFloat32Array,
	sim_seconds: float
) -> Dictionary:
	var sat_changed := PackedInt32Array()
	var tier_changes: Array = []
	var inv_mass := 1.0 / float(mass_total)
	var up_needed := float(SliceConstants.TIER_UP_SECONDS)
	var down_needed := float(SliceConstants.TIER_DOWN_SECONDS)
	var sat_up := SliceConstants.SAT_UP - EPS
	var sat_down := SliceConstants.SAT_DOWN + EPS
	var tier_max := SliceConstants.BUILDING_TIER_MAX
	var tier_min := SliceConstants.BUILDING_TIER_MIN
	var steps := float(SliceConstants.FIELD_QUANT)
	for id in active:
		var faction := owner[id]
		var sat := 0.0
		if faction >= 0 and degree[id] > 0 and cover[id] > 0 and dark[id] == 0:
			var pollution := minf(1.0, float(mass[id]) * inv_mass)
			sat = gates[faction][zone[id]] * (1.0 - tile_congestion[id]) * (1.0 - pollution) * penalties[faction]
		_sat_raw[id] = sat
		var snapped := floorf(sat * steps + 0.5) / steps
		if snapped != _sat_q[id]:
			_sat_q[id] = snapped
			sat_changed.append(id)
		var current := tier[id]
		var timer := _timer[id]
		if sat >= sat_up:
			if current >= tier_max:
				timer = 0.0
			else:
				timer = maxf(timer, 0.0) + sim_seconds
				if timer >= up_needed:
					timer = 0.0
					tier_changes.append([id, current + 1])
		elif sat <= sat_down:
			if current <= tier_min:
				timer = 0.0
			else:
				timer = minf(timer, 0.0) - sim_seconds
				if -timer >= down_needed:
					timer = 0.0
					tier_changes.append([id, current - 1])
		else:
			timer = 0.0
		_timer[id] = timer
	return {"sat_changed": sat_changed, "tier_changes": tier_changes}


## Clears the timer and both satisfaction values of a tile that stopped being a
## building (zone cleared, demolished). Returns true when the quantized value moved.
func deactivate(id: int) -> bool:
	_timer[id] = 0.0
	_sat_raw[id] = 0.0
	if _sat_q[id] == 0.0:
		return false
	_sat_q[id] = 0.0
	return true


## Timer reset without touching satisfaction (zone changed, tier reset).
func reset_timer(id: int) -> void:
	_timer[id] = 0.0


func timer(id: int) -> float:
	return _timer[id]


func set_timer(id: int, value: float) -> void:
	_timer[id] = value


func satisfaction_raw(id: int) -> float:
	return _sat_raw[id]


func satisfaction_q(id: int) -> float:
	return _sat_q[id]


## Mirrors a quantized value loaded from a save so the first tick does not resend it.
func set_satisfaction_q(id: int, value: float) -> void:
	_sat_q[id] = value
	_sat_raw[id] = value


## Non-zero timers as [[id, toward_up_seconds, toward_down_seconds], ...], ascending id.
func timers_sparse() -> Array:
	var rows: Array = []
	for id in _timer.size():
		var value := _timer[id]
		if value == 0.0:
			continue
		if value > 0.0:
			rows.append([id, float(value), 0.0])
		else:
			rows.append([id, 0.0, float(-value)])
	return rows


func restore_timers(raw) -> void:
	if not (raw is Array):
		return
	for row in raw:
		if not (row is Array) or row.size() < 3:
			continue
		var id := int(row[0])
		if id < 0 or id >= _timer.size():
			push_warning("GrowthModel.restore_timers: tile id %d outside the map, skipped" % id)
			continue
		var up := float(row[1])
		var down := float(row[2])
		if up > 0.0:
			_timer[id] = up
		elif down > 0.0:
			_timer[id] = -down
		else:
			_timer[id] = 0.0

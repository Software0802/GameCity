class_name ScoreTick
extends RefCounted

## Scoring snapshot. Weights are locked: pop 40% / fiscal 30% / control 30%.
## pop / fiscal / control are each normalized onto 0–1 with share(): the raw value
## is clamped at 0, then divided by own + opponent (0.5 when both are 0).
## pop_raw / fiscal_raw / control_raw carry the unnormalized values for the HUD.
## total() is the weighted sum of the normalized terms, so it is also 0–1.

class FactionScore:
	extends RefCounted

	## SliceConstants.Owner. FACTION_A or FACTION_B.
	var faction: int = SliceConstants.Owner.FACTION_A
	var pop: float = 0.0
	var fiscal: float = 0.0
	var control: float = 0.0
	var pop_raw: float = 0.0
	var fiscal_raw: float = 0.0
	var control_raw: float = 0.0

	func total() -> float:
		return (
			pop * SliceConstants.SCORE_WEIGHT_POP
			+ fiscal * SliceConstants.SCORE_WEIGHT_FISCAL
			+ control * SliceConstants.SCORE_WEIGHT_CONTROL
		)

	func to_dict() -> Dictionary:
		return {
			"faction": faction,
			"pop": pop,
			"fiscal": fiscal,
			"control": control,
			"pop_raw": pop_raw,
			"fiscal_raw": fiscal_raw,
			"control_raw": control_raw,
			"total": total(),
		}

	static func from_dict(data: Dictionary) -> FactionScore:
		var line := FactionScore.new()
		line.faction = int(data.get("faction", SliceConstants.Owner.FACTION_A))
		line.pop = float(data.get("pop", 0.0))
		line.fiscal = float(data.get("fiscal", 0.0))
		line.control = float(data.get("control", 0.0))
		line.pop_raw = float(data.get("pop_raw", 0.0))
		line.fiscal_raw = float(data.get("fiscal_raw", 0.0))
		line.control_raw = float(data.get("control_raw", 0.0))
		return line


var tick_index: int = 0
## Wall-clock seconds until the round ends. 0 once the clock has run out.
var seconds_remaining: int = 0
var factions: Array[FactionScore] = []


## Normalized share for one scoring term: max(0, own) / (max(0, own) + max(0, other)).
## Both zero gives 0.5. Result is in 0–1.
static func share(own: float, other: float) -> float:
	var mine: float = maxf(0.0, own)
	var theirs: float = maxf(0.0, other)
	var sum := mine + theirs
	if sum <= 0.0:
		return 0.5
	return mine / sum


func to_dict() -> Dictionary:
	var lines: Array = []
	for line in factions:
		if line != null:
			lines.append(line.to_dict())
	return {
		"tick_index": tick_index,
		"seconds_remaining": seconds_remaining,
		"factions": lines,
	}


static func from_dict(data: Dictionary) -> ScoreTick:
	var tick := ScoreTick.new()
	tick.tick_index = int(data.get("tick_index", 0))
	tick.seconds_remaining = int(data.get("seconds_remaining", 0))
	var lines: Array[FactionScore] = []
	var raw_lines = data.get("factions", [])
	if raw_lines is Array:
		for raw in raw_lines:
			if raw is Dictionary:
				lines.append(FactionScore.from_dict(raw))
	tick.factions = lines
	return tick

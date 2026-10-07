class_name ScoreTick
extends RefCounted

## Scoring snapshot. Weights are locked: pop 40% / fiscal 30% / control 30%.
## Component values are placeholders. total applies those weights and does not
## normalize each term onto 0–1 (that scale is still unfixed).

class FactionScore:
	extends RefCounted

	## SliceConstants.Owner. FACTION_A or FACTION_B.
	var faction: int = SliceConstants.Owner.FACTION_A
	var pop: float = 0.0
	var fiscal: float = 0.0
	var control: float = 0.0

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
			"total": total(),
		}

	static func from_dict(data: Dictionary) -> FactionScore:
		var line := FactionScore.new()
		line.faction = int(data.get("faction", SliceConstants.Owner.FACTION_A))
		line.pop = float(data.get("pop", 0.0))
		line.fiscal = float(data.get("fiscal", 0.0))
		line.control = float(data.get("control", 0.0))
		return line


var tick_index: int = 0
var factions: Array[FactionScore] = []


func to_dict() -> Dictionary:
	var lines: Array = []
	for line in factions:
		if line != null:
			lines.append(line.to_dict())
	return {
		"tick_index": tick_index,
		"factions": lines,
	}


static func from_dict(data: Dictionary) -> ScoreTick:
	var tick := ScoreTick.new()
	tick.tick_index = int(data.get("tick_index", 0))
	var lines: Array[FactionScore] = []
	var raw_lines = data.get("factions", [])
	if raw_lines is Array:
		for raw in raw_lines:
			if raw is Dictionary:
				lines.append(FactionScore.from_dict(raw))
	tick.factions = lines
	return tick

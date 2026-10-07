class_name PowerAlert
extends RefCounted

## Power notice for one tile: coverage changed, or the tile is short of power.
## This is not a second power ruleset. powerCovered is still written by the sim tick.

var x: int = 0
var y: int = 0
var power_covered: bool = false
var shortage: bool = false


func to_dict() -> Dictionary:
	return {
		"x": x,
		"y": y,
		"power_covered": power_covered,
		"shortage": shortage,
	}


static func from_dict(data: Dictionary) -> PowerAlert:
	var alert := PowerAlert.new()
	alert.x = int(data.get("x", 0))
	alert.y = int(data.get("y", 0))
	alert.power_covered = bool(data.get("power_covered", false))
	alert.shortage = bool(data.get("shortage", false))
	return alert

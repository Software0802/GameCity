class_name PowerAlert
extends RefCounted

## Power notice for one tile: coverage changed, the tile is short of power, or the
## covering plant is over capacity (brownout). This is not a second power ruleset;
## power_covered and brownout are still written by the sim tick.

var x: int = 0
var y: int = 0
var power_covered: bool = false
var shortage: bool = false
var brownout: bool = false


func to_dict() -> Dictionary:
	return {
		"x": x,
		"y": y,
		"power_covered": power_covered,
		"shortage": shortage,
		"brownout": brownout,
	}


static func from_dict(data: Dictionary) -> PowerAlert:
	var alert := PowerAlert.new()
	alert.x = int(data.get("x", 0))
	alert.y = int(data.get("y", 0))
	alert.power_covered = bool(data.get("power_covered", false))
	alert.shortage = bool(data.get("shortage", false))
	alert.brownout = bool(data.get("brownout", false))
	return alert

class_name CrisisEvent
extends RefCounted

## The one shared mid-match crisis. Both factions receive the same payload.

var crisis_id: String = ""
var active: bool = false
var detail: String = ""


func to_dict() -> Dictionary:
	return {
		"crisis_id": crisis_id,
		"active": active,
		"detail": detail,
	}


static func from_dict(data: Dictionary) -> CrisisEvent:
	var crisis := CrisisEvent.new()
	crisis.crisis_id = str(data.get("crisis_id", ""))
	crisis.active = bool(data.get("active", false))
	crisis.detail = str(data.get("detail", ""))
	return crisis

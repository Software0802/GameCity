class_name CrisisEvent
extends RefCounted

## The one shared mid-round crisis. Both factions receive the same payload.
## kind names the crisis (KIND_GRID_STORM in M2). ends_at_unix is the wall-clock
## second the effect stops; 0 when unknown or when active is false.

const KIND_GRID_STORM := "grid_storm"

var crisis_id: String = ""
var kind: String = ""
var active: bool = false
var detail: String = ""
var ends_at_unix: int = 0


func to_dict() -> Dictionary:
	return {
		"crisis_id": crisis_id,
		"kind": kind,
		"active": active,
		"detail": detail,
		"ends_at_unix": ends_at_unix,
	}


static func from_dict(data: Dictionary) -> CrisisEvent:
	var crisis := CrisisEvent.new()
	crisis.crisis_id = str(data.get("crisis_id", ""))
	crisis.kind = str(data.get("kind", ""))
	crisis.active = bool(data.get("active", false))
	crisis.detail = str(data.get("detail", ""))
	crisis.ends_at_unix = int(data.get("ends_at_unix", 0))
	return crisis

class_name InterestUpdate
extends RefCounted

## Change in one client's subscribed interest set.
## add / remove hold InterestId. The wire also accepts linear ids.

var add: Array[InterestId] = []
var remove: Array[InterestId] = []


func to_dict() -> Dictionary:
	return {
		"add": _pack(add),
		"remove": _pack(remove),
	}


static func from_dict(data: Dictionary) -> InterestUpdate:
	var update := InterestUpdate.new()
	update.add = _unpack(data.get("add", []))
	update.remove = _unpack(data.get("remove", []))
	return update


func _pack(ids: Array[InterestId]) -> Array:
	var packed: Array = []
	for interest_id in ids:
		if interest_id != null:
			packed.append(interest_id.to_dict())
	return packed


static func _unpack(raw) -> Array[InterestId]:
	var ids: Array[InterestId] = []
	if raw is Array:
		for entry in raw:
			ids.append(InterestId.from_any(entry))
	return ids

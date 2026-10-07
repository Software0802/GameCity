class_name CongestionAlert
extends RefCounted

## Congestion notice for one orthogonal edge. The value is a placeholder
## until the sim tick owns the formula.

var a: Vector2i = Vector2i(-1, -1)
var b: Vector2i = Vector2i(-1, -1)
var congestion: float = 0.0


func to_dict() -> Dictionary:
	return {
		"a": EdgeDelta.point_to_dict(a),
		"b": EdgeDelta.point_to_dict(b),
		"congestion": congestion,
	}


static func from_dict(data: Dictionary) -> CongestionAlert:
	var alert := CongestionAlert.new()
	alert.a = EdgeDelta.point_from_dict(data.get("a", {}))
	alert.b = EdgeDelta.point_from_dict(data.get("b", {}))
	alert.congestion = float(data.get("congestion", 0.0))
	return alert

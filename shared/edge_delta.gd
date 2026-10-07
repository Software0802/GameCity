class_name EdgeDelta
extends RefCounted

## edge{ a, b, capacity, congestion }. Orthogonal 4-neighbor only.
## removed=true is the v0 way to express RemoveEdge on the wire.

var a: Vector2i = Vector2i(-1, -1)
var b: Vector2i = Vector2i(-1, -1)
var capacity: int = 0
var congestion: float = 0.0
var removed: bool = false

## True when a and b are distinct 4-neighbors (no diagonals).
static func is_orthogonal(a: Vector2i, b: Vector2i) -> bool:
	var delta: Vector2i = (a - b).abs()
	return delta.x + delta.y == 1


## Wire form of RemoveEdge: same endpoints, removed set.
static func make_removed(p_a: Vector2i, p_b: Vector2i) -> EdgeDelta:
	var edge := EdgeDelta.new()
	edge.a = p_a
	edge.b = p_b
	edge.removed = true
	return edge


static func point_to_dict(point: Vector2i) -> Dictionary:
	return {"x": point.x, "y": point.y}


## Dictionary {"x","y"} is the canonical form. Vector2i is accepted for a later RPC dict.
static func point_from_dict(raw) -> Vector2i:
	if raw is Vector2i:
		return raw
	if raw is Dictionary:
		return Vector2i(int(raw.get("x", -1)), int(raw.get("y", -1)))
	return Vector2i(-1, -1)


func to_dict() -> Dictionary:
	return {
		"a": point_to_dict(a),
		"b": point_to_dict(b),
		"capacity": capacity,
		"congestion": congestion,
		"removed": removed,
	}


static func from_dict(data: Dictionary) -> EdgeDelta:
	var edge := EdgeDelta.new()
	edge.a = point_from_dict(data.get("a", {}))
	edge.b = point_from_dict(data.get("b", {}))
	edge.capacity = int(data.get("capacity", 0))
	edge.congestion = float(data.get("congestion", 0.0))
	edge.removed = bool(data.get("removed", false))
	return edge

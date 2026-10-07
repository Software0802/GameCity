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

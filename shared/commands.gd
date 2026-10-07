class_name GameCommand
extends RefCounted

## Client → server intents. Payload only; the server accepts or rejects.
## See docs/briefs/gameplay-vertical-slice.md and netcode-interface-v0.md.
##
## validate_shape() checks bounds, orthogonal edges, and the zone enum.
## Ownership and adjacency stay on the server.

enum Kind {
	CLAIM_TILE,
	SET_ZONE,
	ADD_EDGE,
	REMOVE_EDGE,
	PLACE_POWER,
	REMOVE_POWER,
	DEMOLISH_OWN,
}

var kind: Kind = Kind.CLAIM_TILE
var tile_x: int = -1
var tile_y: int = -1
## SliceConstants.Zone. Used by SET_ZONE.
var zone: int = SliceConstants.Zone.NONE
## Tile coordinates of the two cells an orthogonal edge connects.
var edge_a: Vector2i = Vector2i(-1, -1)
var edge_b: Vector2i = Vector2i(-1, -1)


func _init(p_kind: Kind = Kind.CLAIM_TILE) -> void:
	kind = p_kind


static func claim_tile(x: int, y: int) -> GameCommand:
	return _on_tile(Kind.CLAIM_TILE, x, y)


static func set_zone(x: int, y: int, p_zone: int) -> GameCommand:
	var cmd := _on_tile(Kind.SET_ZONE, x, y)
	cmd.zone = p_zone
	return cmd


static func add_edge(a: Vector2i, b: Vector2i) -> GameCommand:
	return _on_edge(Kind.ADD_EDGE, a, b)


static func remove_edge(a: Vector2i, b: Vector2i) -> GameCommand:
	return _on_edge(Kind.REMOVE_EDGE, a, b)


static func place_power(x: int, y: int) -> GameCommand:
	return _on_tile(Kind.PLACE_POWER, x, y)


static func remove_power(x: int, y: int) -> GameCommand:
	return _on_tile(Kind.REMOVE_POWER, x, y)


static func demolish_own(x: int, y: int) -> GameCommand:
	return _on_tile(Kind.DEMOLISH_OWN, x, y)


## Returns ReasonCode.Id. OK means the shape is recognizable, not that the rule passed.
func validate_shape() -> int:
	match kind:
		Kind.CLAIM_TILE, Kind.PLACE_POWER, Kind.REMOVE_POWER, Kind.DEMOLISH_OWN:
			if not SliceConstants.in_map(tile_x, tile_y):
				return ReasonCode.Id.OUT_OF_BOUNDS
		Kind.SET_ZONE:
			if not SliceConstants.in_map(tile_x, tile_y):
				return ReasonCode.Id.OUT_OF_BOUNDS
			if not SliceConstants.is_zone(zone):
				return ReasonCode.Id.INVALID_ZONE
		Kind.ADD_EDGE, Kind.REMOVE_EDGE:
			if (
				not SliceConstants.in_map(edge_a.x, edge_a.y)
				or not SliceConstants.in_map(edge_b.x, edge_b.y)
			):
				return ReasonCode.Id.OUT_OF_BOUNDS
			if not EdgeDelta.is_orthogonal(edge_a, edge_b):
				return ReasonCode.Id.NOT_ORTHOGONAL
		_:
			return ReasonCode.Id.UNKNOWN_COMMAND
	return ReasonCode.Id.OK


func to_dict() -> Dictionary:
	return {
		"kind": int(kind),
		"tile_x": tile_x,
		"tile_y": tile_y,
		"zone": zone,
		"edge_a": EdgeDelta.point_to_dict(edge_a),
		"edge_b": EdgeDelta.point_to_dict(edge_b),
	}


static func from_dict(data: Dictionary) -> GameCommand:
	var cmd := GameCommand.new()
	cmd.kind = int(data.get("kind", Kind.CLAIM_TILE))
	cmd.tile_x = int(data.get("tile_x", -1))
	cmd.tile_y = int(data.get("tile_y", -1))
	cmd.zone = int(data.get("zone", SliceConstants.Zone.NONE))
	cmd.edge_a = EdgeDelta.point_from_dict(data.get("edge_a", {}))
	cmd.edge_b = EdgeDelta.point_from_dict(data.get("edge_b", {}))
	return cmd


static func _on_tile(p_kind: Kind, x: int, y: int) -> GameCommand:
	var cmd := GameCommand.new(p_kind)
	cmd.tile_x = x
	cmd.tile_y = y
	return cmd


static func _on_edge(p_kind: Kind, a: Vector2i, b: Vector2i) -> GameCommand:
	var cmd := GameCommand.new(p_kind)
	cmd.edge_a = a
	cmd.edge_b = b
	return cmd

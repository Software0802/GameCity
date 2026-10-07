class_name GameCommand
extends RefCounted

## Client → server intents. Payload only; the server accepts or rejects.
## See docs/briefs/gameplay-vertical-slice.md and netcode-interface-v0.md.

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

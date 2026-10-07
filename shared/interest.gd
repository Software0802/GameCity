class_name InterestId
extends RefCounted

## Interest region id. Map is 64×64 tiles; one region is 8×8 tiles (64 regions).

var block_x: int = 0
var block_y: int = 0

func _init(bx: int = 0, by: int = 0) -> void:
	block_x = bx
	block_y = by

static func from_tile(tile_x: int, tile_y: int) -> InterestId:
	return InterestId.new(
		int(tile_x / SliceConstants.INTEREST_BLOCK),
		int(tile_y / SliceConstants.INTEREST_BLOCK)
	)

## Linear id in 0 .. BLOCKS_PER_AXIS²-1, row-major.
func linear_id() -> int:
	return block_y * SliceConstants.BLOCKS_PER_AXIS + block_x

func key() -> String:
	return "%d,%d" % [block_x, block_y]

class_name InterestId
extends RefCounted

## Interest region id. Map is MAP_SIZE×MAP_SIZE tiles; one region is INTEREST_BLOCK×INTEREST_BLOCK
## tiles, so there are BLOCKS_PER_AXIS² regions (16×16 = 256 at MAP_SIZE 128).

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


static func from_linear(linear: int) -> InterestId:
	var axis := SliceConstants.BLOCKS_PER_AXIS
	return InterestId.new(linear % axis, int(linear / axis))


static func from_key(text: String) -> InterestId:
	var parts := text.split(",")
	if parts.size() != 2:
		return InterestId.new()
	return InterestId.new(int(parts[0]), int(parts[1]))


func to_dict() -> Dictionary:
	return {
		"block_x": block_x,
		"block_y": block_y,
		"linear_id": linear_id(),
		"key": key(),
	}


## Prefers block coordinates, then linear_id, then "bx,by".
static func from_dict(data: Dictionary) -> InterestId:
	if data.has("block_x") or data.has("block_y"):
		return InterestId.new(int(data.get("block_x", 0)), int(data.get("block_y", 0)))
	if data.has("linear_id"):
		return from_linear(int(data["linear_id"]))
	if data.has("key"):
		return from_key(str(data["key"]))
	return InterestId.new()


## InterestUpdate entries may be an InterestId, a linear id, a "bx,by" key, or a dict.
static func from_any(value) -> InterestId:
	if value is InterestId:
		return value
	if value is int:
		return from_linear(value)
	if value is float:
		return from_linear(int(value))
	if value is String:
		return from_key(value)
	if value is Dictionary:
		return from_dict(value)
	return InterestId.new()

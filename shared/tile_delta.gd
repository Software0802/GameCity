class_name TileDelta
extends RefCounted

## Full tile snapshot used as the TileDelta.
## tile{ id, x, y, owner, zone, hasBuilding, buildingTier, powerCovered,
##       satisfaction, pollution, brownout }
## power_covered means "inside some plant's radius". Actual power =
## power_covered and not brownout.

var id: int = -1
var x: int = 0
var y: int = 0
## SliceConstants.Owner. faction or neutral.
var owner: int = SliceConstants.Owner.NEUTRAL
## SliceConstants.Zone. R, C, I, or none.
var zone: int = SliceConstants.Zone.NONE
var has_building: bool = false
## 0–2. See SliceConstants.BUILDING_TIER_*.
var building_tier: int = 0
var power_covered: bool = false
## 0–1, quantized to 1/FIELD_QUANT by the sim before it is sent.
var satisfaction: float = 0.0
## 0–1, quantized to 1/FIELD_QUANT by the sim before it is sent.
var pollution: float = 0.0
## True while the covering plant is over capacity.
var brownout: bool = false

static func from_cell(cell_x: int, cell_y: int) -> TileDelta:
	var tile := TileDelta.new()
	tile.x = cell_x
	tile.y = cell_y
	tile.id = SliceConstants.tile_id(cell_x, cell_y)
	return tile


func to_dict() -> Dictionary:
	return {
		"id": id,
		"x": x,
		"y": y,
		"owner": owner,
		"zone": zone,
		"has_building": has_building,
		"building_tier": building_tier,
		"power_covered": power_covered,
		"satisfaction": satisfaction,
		"pollution": pollution,
		"brownout": brownout,
	}


static func from_dict(data: Dictionary) -> TileDelta:
	var tile := TileDelta.new()
	tile.x = int(data.get("x", 0))
	tile.y = int(data.get("y", 0))
	tile.id = int(data.get("id", SliceConstants.tile_id(tile.x, tile.y)))
	tile.owner = int(data.get("owner", SliceConstants.Owner.NEUTRAL))
	tile.zone = int(data.get("zone", SliceConstants.Zone.NONE))
	tile.has_building = bool(data.get("has_building", false))
	tile.building_tier = int(data.get("building_tier", 0))
	tile.power_covered = bool(data.get("power_covered", false))
	tile.satisfaction = float(data.get("satisfaction", 0.0))
	tile.pollution = float(data.get("pollution", 0.0))
	tile.brownout = bool(data.get("brownout", false))
	return tile

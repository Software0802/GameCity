extends RefCounted

## Power coverage, per-plant load, and brownout. Pure data: tile ids in, tile ids out.
##
## A tile is covered when it lies inside at least one plant's service square: the
## (2 × POWER_RADIUS + 1)² tiles around the plant, Chebyshev distance ≤ POWER_RADIUS
## (TileDelta.power_covered). A square, not a Manhattan diamond, so one plant at
## the centre of an 8×8 spawn block covers the whole block (81 tiles; the diamond
## held 41 and left the block's corners dark).
##
## A building weighs tier + 1 regardless of owner. A tile covered by n plants gives
## each of them 1/n of its weight, so a plant's load is Σ weight / cover over its
## square and a second plant placed beside an overloaded one takes over part of its
## load instead of counting it twice. Shares are kept in integer units of
## SHARE_UNIT / n (SHARE_UNIT = lcm(1..10) = 2520: up to ten overlapping plants split
## exactly; beyond that the division rounds down a little, identically on add and
## remove, so loads never drift and a restored world rebuilds the same numbers).
## load > capacity() puts every tile in that plant's square into brownout; a tile is
## dark while any overloaded plant covers it. Actual power is covered and not
## brownout.
##
## Coverage counts and loads are kept incrementally: set_weight() is O(plants over
## the tile); add_plant() / remove_plant() re-share the weights in the square among
## the plants already there, O(square × plants over each tile). resolve()
## re-evaluates only the plants marked dirty since the last call, so a tick with no
## structural change costs nothing here. set_crisis() marks every plant dirty
## because capacity() changes.

## Units one tile's full weight is worth; a tile covered by n plants hands each
## SHARE_UNIT / n of them.
const SHARE_UNIT := 2520


class Plant:
	extends RefCounted

	var id: int = -1
	var owner: int = SliceConstants.Owner.NEUTRAL
	## Tile ids inside the radius, clipped to the map.
	var tiles: PackedInt32Array = PackedInt32Array()
	## Σ weight × SHARE_UNIT / cover over tiles, in share units.
	var load: int = 0
	var over: bool = false


var _cover: PackedInt32Array = PackedInt32Array()
var _dark: PackedInt32Array = PackedInt32Array()
var _weight: PackedInt32Array = PackedInt32Array()
## Per tile, the ids of the plants covering it (PackedInt32Array each), so a
## weight change reaches its plants without scanning the radius.
var _covering: Array = []
var _plants: Dictionary = {}
var _dirty: Dictionary = {}
var _crisis: bool = false
var _dx: PackedInt32Array = PackedInt32Array()
var _dy: PackedInt32Array = PackedInt32Array()


func _init() -> void:
	var count := SliceConstants.MAP_SIZE * SliceConstants.MAP_SIZE
	_cover.resize(count)
	_cover.fill(0)
	_dark.resize(count)
	_dark.fill(0)
	_weight.resize(count)
	_weight.fill(0)
	_covering.resize(count)
	for id in count:
		_covering[id] = PackedInt32Array()
	var radius := SliceConstants.POWER_RADIUS
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			_dx.append(dx)
			_dy.append(dy)


## Share units one plant gets from a tile covered by cover plants.
static func share(cover: int) -> int:
	if cover <= 0:
		return 0
	return SHARE_UNIT / cover


## POWER_PLANT_CAPACITY, times CRISIS_CAPACITY_FACTOR while the grid storm is on.
func capacity() -> int:
	if _crisis:
		return int(floor(float(SliceConstants.POWER_PLANT_CAPACITY) * SliceConstants.CRISIS_CAPACITY_FACTOR))
	return SliceConstants.POWER_PLANT_CAPACITY


func set_crisis(active: bool) -> void:
	if _crisis == active:
		return
	_crisis = active
	for id in _plants:
		_dirty[id] = true


func crisis() -> bool:
	return _crisis


func covered(id: int) -> bool:
	return _cover[id] > 0


func cover_count(id: int) -> int:
	return _cover[id]


func brownout(id: int) -> bool:
	return _dark[id] > 0


func powered(id: int) -> bool:
	return _cover[id] > 0 and _dark[id] == 0


func has_plant(id: int) -> bool:
	return _plants.has(id)


func plant_count() -> int:
	return _plants.size()


## Load of a plant in weight units (its shares summed); 0 without a plant. A whole
## number while nothing in its square is shared.
func plant_load(id: int) -> float:
	return float(plant_load_units(id)) / float(SHARE_UNIT)


## Load of a plant in share units.
func plant_load_units(id: int) -> int:
	if not _plants.has(id):
		return 0
	return _plants[id].load


func plant_over(id: int) -> bool:
	if not _plants.has(id):
		return false
	return _plants[id].over


## Ascending tile ids, for the save.
func plant_ids_sorted() -> Array:
	var ids: Array = _plants.keys()
	ids.sort()
	return ids


## Adds a plant and returns the tile ids whose coverage switched on. Every plant
## already covering a tile in the square gives up part of that tile's weight to the
## new one. The plants touched are marked dirty; call resolve() to learn which are
## over capacity now.
func add_plant(id: int, owner: int) -> PackedInt32Array:
	var turned_on := PackedInt32Array()
	if _plants.has(id):
		return turned_on
	var plant := Plant.new()
	plant.id = id
	plant.owner = owner
	plant.tiles = _square(id)
	var load := 0
	for tile in plant.tiles:
		var before := _cover[tile]
		var weight := _weight[tile]
		if before == 0:
			turned_on.append(tile)
		elif weight != 0:
			var delta := weight * (share(before + 1) - share(before))
			for other in _covering[tile]:
				_plants[other].load += delta
				_dirty[other] = true
		_cover[tile] = before + 1
		load += weight * share(before + 1)
		var list: PackedInt32Array = _covering[tile]
		list.append(id)
		_covering[tile] = list
	plant.load = load
	_plants[id] = plant
	_dirty[id] = true
	return turned_on


## Removes a plant and returns the tile ids whose coverage or brownout changed. The
## remaining plants over each tile take the removed plant's share back.
func remove_plant(id: int) -> PackedInt32Array:
	var changed := PackedInt32Array()
	if not _plants.has(id):
		return changed
	var plant: Plant = _plants[id]
	_plants.erase(id)
	_dirty.erase(id)
	var touched: Dictionary = {}
	for tile in plant.tiles:
		var before := _cover[tile]
		_cover[tile] = before - 1
		var list: PackedInt32Array = _covering[tile]
		var at := list.find(id)
		if at >= 0:
			list.remove_at(at)
		_covering[tile] = list
		if before == 1:
			touched[tile] = true
			continue
		var weight := _weight[tile]
		if weight != 0:
			var delta := weight * (share(before - 1) - share(before))
			for other in list:
				_plants[other].load += delta
				_dirty[other] = true
	if plant.over:
		for tile in plant.tiles:
			_dark[tile] -= 1
			if _dark[tile] == 0:
				touched[tile] = true
	for tile in touched:
		changed.append(tile)
	return changed


## Load weight of one tile: tier + 1 for a building, 0 for none. Every plant that
## covers the tile takes its share of the difference and is marked dirty.
func set_weight(id: int, weight: int) -> void:
	var delta := weight - _weight[id]
	if delta == 0:
		return
	_weight[id] = weight
	var cover := _cover[id]
	if cover == 0:
		return
	var units := delta * share(cover)
	for plant_id in _covering[id]:
		_plants[plant_id].load += units
		_dirty[plant_id] = true


## Re-evaluates dirty plants against capacity(). Returns
## {"tiles": PackedInt32Array of tile ids whose brownout flag flipped,
##  "alerts": [[plant_id, over], ...] one per plant whose state flipped}.
func resolve() -> Dictionary:
	var flipped := PackedInt32Array()
	var alerts: Array = []
	if _dirty.is_empty():
		return {"tiles": flipped, "alerts": alerts}
	var cap_units := capacity() * SHARE_UNIT
	var touched: Dictionary = {}
	for id in _dirty:
		var plant: Plant = _plants[id]
		var over := plant.load > cap_units
		if over == plant.over:
			continue
		plant.over = over
		if over:
			for tile in plant.tiles:
				_dark[tile] += 1
				if _dark[tile] == 1:
					touched[tile] = true
		else:
			for tile in plant.tiles:
				_dark[tile] -= 1
				if _dark[tile] == 0:
					touched[tile] = true
		alerts.append([id, over])
	_dirty.clear()
	for tile in touched:
		flipped.append(tile)
	return {"tiles": flipped, "alerts": alerts}


## Σ capacity over the faction's plants.
func faction_capacity(faction: int) -> int:
	var cap := capacity()
	var total := 0
	for id in _plants:
		if _plants[id].owner == faction:
			total += cap
	return total


## Σ load over the faction's plants, rounded to whole weight units.
func faction_load(faction: int) -> int:
	var total := 0
	for id in _plants:
		var plant: Plant = _plants[id]
		if plant.owner == faction:
			total += plant.load
	return roundi(float(total) / float(SHARE_UNIT))


## Copy-on-write views for the growth pass; read only.
func cover_array() -> PackedInt32Array:
	return _cover


func dark_array() -> PackedInt32Array:
	return _dark


## Tile ids of the plant's service square, clipped to the map.
func _square(id: int) -> PackedInt32Array:
	var tiles := PackedInt32Array()
	var size := SliceConstants.MAP_SIZE
	var x := id % size
	var y := int(id / size)
	for i in _dx.size():
		var nx := x + _dx[i]
		var ny := y + _dy[i]
		if nx < 0 or ny < 0 or nx >= size or ny >= size:
			continue
		tiles.append(ny * size + nx)
	return tiles

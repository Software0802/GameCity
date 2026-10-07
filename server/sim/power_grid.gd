extends RefCounted

## Power coverage, per-plant load, and brownout. Pure data: tile ids in, tile ids out.
##
## A tile is covered when at least one plant's Manhattan radius POWER_RADIUS
## reaches it (TileDelta.power_covered). A plant's load is Σ (tier + 1) over the
## building tiles in its radius, regardless of owner and without sharing between
## overlapping plants. load > capacity() puts every tile in that plant's radius
## into brownout; a tile is dark while any overloaded plant covers it. Actual power
## is covered and not brownout.
##
## Coverage counts and loads are kept incrementally (add/remove plant, set_weight);
## resolve() re-evaluates only the plants marked dirty since the last call, so a tick
## with no structural change costs nothing here. set_crisis() marks every plant
## dirty because capacity() changes.

class Plant:
	extends RefCounted

	var id: int = -1
	var owner: int = SliceConstants.Owner.NEUTRAL
	## Tile ids inside the radius, clipped to the map.
	var tiles: PackedInt32Array = PackedInt32Array()
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
			if absi(dx) + absi(dy) > radius:
				continue
			_dx.append(dx)
			_dy.append(dy)


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


func brownout(id: int) -> bool:
	return _dark[id] > 0


func powered(id: int) -> bool:
	return _cover[id] > 0 and _dark[id] == 0


func has_plant(id: int) -> bool:
	return _plants.has(id)


func plant_count() -> int:
	return _plants.size()


func plant_load(id: int) -> int:
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


## Adds a plant and returns the tile ids whose coverage switched on. The plant is
## marked dirty; call resolve() to learn whether it is already over capacity.
func add_plant(id: int, owner: int) -> PackedInt32Array:
	var turned_on := PackedInt32Array()
	if _plants.has(id):
		return turned_on
	var plant := Plant.new()
	plant.id = id
	plant.owner = owner
	plant.tiles = _diamond(id)
	var load := 0
	for tile in plant.tiles:
		_cover[tile] += 1
		if _cover[tile] == 1:
			turned_on.append(tile)
		load += _weight[tile]
		var list: PackedInt32Array = _covering[tile]
		list.append(id)
		_covering[tile] = list
	plant.load = load
	_plants[id] = plant
	_dirty[id] = true
	return turned_on


## Removes a plant and returns the tile ids whose coverage or brownout changed.
func remove_plant(id: int) -> PackedInt32Array:
	var changed := PackedInt32Array()
	if not _plants.has(id):
		return changed
	var plant: Plant = _plants[id]
	_plants.erase(id)
	_dirty.erase(id)
	var touched: Dictionary = {}
	for tile in plant.tiles:
		_cover[tile] -= 1
		if _cover[tile] == 0:
			touched[tile] = true
		var list: PackedInt32Array = _covering[tile]
		var at := list.find(id)
		if at >= 0:
			list.remove_at(at)
		_covering[tile] = list
	if plant.over:
		for tile in plant.tiles:
			_dark[tile] -= 1
			if _dark[tile] == 0:
				touched[tile] = true
	for tile in touched:
		changed.append(tile)
	return changed


## Load weight of one tile: tier + 1 for a building, 0 for none. Every plant that
## covers the tile takes the difference and is marked dirty.
func set_weight(id: int, weight: int) -> void:
	var delta := weight - _weight[id]
	if delta == 0:
		return
	_weight[id] = weight
	if _cover[id] == 0:
		return
	for plant_id in _covering[id]:
		_plants[plant_id].load += delta
		_dirty[plant_id] = true


## Re-evaluates dirty plants against capacity(). Returns
## {"tiles": PackedInt32Array of tile ids whose brownout flag flipped,
##  "alerts": [[plant_id, over], ...] one per plant whose state flipped}.
func resolve() -> Dictionary:
	var flipped := PackedInt32Array()
	var alerts: Array = []
	if _dirty.is_empty():
		return {"tiles": flipped, "alerts": alerts}
	var cap := capacity()
	var touched: Dictionary = {}
	for id in _dirty:
		var plant: Plant = _plants[id]
		var over := plant.load > cap
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


## Σ load over the faction's plants.
func faction_load(faction: int) -> int:
	var total := 0
	for id in _plants:
		var plant: Plant = _plants[id]
		if plant.owner == faction:
			total += plant.load
	return total


## Copy-on-write views for the growth pass; read only.
func cover_array() -> PackedInt32Array:
	return _cover


func dark_array() -> PackedInt32Array:
	return _dark


func _diamond(id: int) -> PackedInt32Array:
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

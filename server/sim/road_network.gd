extends RefCounted

## Orthogonal road edges, per-tile road access, and the local congestion model.
##
## edges is the authoritative Dictionary edge key → EdgeDelta (ordered endpoints);
## WorldState exposes it unchanged for snapshots and the save. Internally every
## edge also sits in one of two slot arrays indexed by its west / north tile
## (_east for horizontal, _south for vertical), so the edges touching a tile are
## four array reads and no string keys. A tile "has a road" when its degree is > 0.
##
## Congestion of an edge = load / CONGESTION_CAPACITY clamped to 1 and quantized to
## 1/FIELD_QUANT, where load = tier(a) + tier(b) + ½ Σ over the edges sharing an
## endpoint of (tier of their two ends). Owners are never consulted. With
## far(t) = Σ over t's edges of the tier at the other end, the same load is
## ½ (deg(a) tier(a) + deg(b) tier(b) + far(a) + far(b)), which is what resolve()
## evaluates in O(1) per edge; far() is kept current by set_tier / add / remove.
## set_tier() and add()/remove() mark the tiles whose edges can change; resolve()
## recomputes only those edges and returns the ones whose quantized value moved,
## which is exactly when a CongestionAlert goes out. tile_congestion() is the mean
## over a tile's incident edges, refreshed by resolve().

var edges: Dictionary = {}

var _east: Array = []
var _south: Array = []
var _degree: PackedInt32Array = PackedInt32Array()
var _tier: PackedInt32Array = PackedInt32Array()
var _far: PackedInt32Array = PackedInt32Array()
var _tile_congestion: PackedFloat32Array = PackedFloat32Array()
var _dirty_tiles: Dictionary = {}

const SIZE := SliceConstants.MAP_SIZE


func _init() -> void:
	var count := SIZE * SIZE
	_east.resize(count)
	_south.resize(count)
	_degree.resize(count)
	_degree.fill(0)
	_tier.resize(count)
	_tier.fill(0)
	_far.resize(count)
	_far.fill(0)
	_tile_congestion.resize(count)
	_tile_congestion.fill(0.0)


static func ordered(a: Vector2i, b: Vector2i) -> EdgeDelta:
	var edge := EdgeDelta.new()
	if a.x < b.x or (a.x == b.x and a.y <= b.y):
		edge.a = a
		edge.b = b
	else:
		edge.a = b
		edge.b = a
	return edge


static func key(a: Vector2i, b: Vector2i) -> String:
	var edge := ordered(a, b)
	return "%d,%d:%d,%d" % [edge.a.x, edge.a.y, edge.b.x, edge.b.y]


func find(a: Vector2i, b: Vector2i) -> EdgeDelta:
	return edges.get(key(a, b))


func has_road(id: int) -> bool:
	return _degree[id] > 0


func degree(id: int) -> int:
	return _degree[id]


func tile_congestion(id: int) -> float:
	return _tile_congestion[id]


## Adds the edge with CONGESTION_CAPACITY and zero congestion. Returns null when
## it already exists (nothing changes). Both endpoints are marked dirty, which
## covers the new edge and every edge adjacent to it.
func add(a: Vector2i, b: Vector2i) -> EdgeDelta:
	var k := key(a, b)
	if edges.has(k):
		return null
	var edge := ordered(a, b)
	edge.capacity = SliceConstants.CONGESTION_CAPACITY
	edge.congestion = 0.0
	edge.removed = false
	_insert(k, edge)
	_dirty_tiles[_id(edge.a)] = true
	_dirty_tiles[_id(edge.b)] = true
	return edge


## Removes the edge. Returns false when it was not there.
func remove(a: Vector2i, b: Vector2i) -> bool:
	var k := key(a, b)
	if not edges.has(k):
		return false
	var edge: EdgeDelta = edges[k]
	edges.erase(k)
	var id_a := _id(edge.a)
	var id_b := _id(edge.b)
	if edge.a.y == edge.b.y:
		_east[id_a] = null
	else:
		_south[id_a] = null
	_degree[id_a] -= 1
	_degree[id_b] -= 1
	_far[id_a] -= _tier[id_b]
	_far[id_b] -= _tier[id_a]
	_dirty_tiles[id_a] = true
	_dirty_tiles[id_b] = true
	return true


## Inserts a saved edge as-is (capacity and congestion kept) without marking
## anything dirty. Call rebuild_tile_congestion() once all edges are restored.
func restore(edge: EdgeDelta) -> void:
	var k := key(edge.a, edge.b)
	if edges.has(k):
		return
	var stored := ordered(edge.a, edge.b)
	stored.capacity = edge.capacity
	stored.congestion = edge.congestion
	stored.removed = false
	_insert(k, stored)


## Building tier of a tile as the load model sees it. Marks the tile and its road
## neighbours dirty: those are the endpoints of every edge whose load reads it.
func set_tier(id: int, tier: int) -> void:
	var delta := tier - _tier[id]
	if delta == 0:
		return
	_tier[id] = tier
	if _degree[id] == 0:
		return
	_dirty_tiles[id] = true
	for edge in incident_by_id(id):
		var other := _id(edge.b) if _id(edge.a) == id else _id(edge.a)
		_far[other] += delta
		_dirty_tiles[other] = true


## Recomputes every edge touching a dirty tile. Returns the edges whose quantized
## congestion changed (the caller sends one CongestionAlert each).
func resolve() -> Array:
	var changed: Array = []
	if _dirty_tiles.is_empty():
		return changed
	var done: Dictionary = {}
	var endpoints: Dictionary = {}
	var inv_capacity := 1.0 / float(SliceConstants.CONGESTION_CAPACITY)
	var steps := float(SliceConstants.FIELD_QUANT)
	for id in _dirty_tiles:
		if _degree[id] == 0:
			continue
		for edge in incident_by_id(id):
			if done.has(edge):
				continue
			done[edge] = true
			var id_a := _id(edge.a)
			var id_b := _id(edge.b)
			var load := 0.5 * float(_degree[id_a] * _tier[id_a] + _degree[id_b] * _tier[id_b] + _far[id_a] + _far[id_b])
			var next := floorf(clampf(load * inv_capacity, 0.0, 1.0) * steps + 0.5) / steps
			if next != edge.congestion:
				edge.congestion = next
				changed.append(edge)
				endpoints[id_a] = true
				endpoints[id_b] = true
	for id in _dirty_tiles:
		endpoints[id] = true
	for id in endpoints:
		_refresh_tile_congestion(id)
	_dirty_tiles.clear()
	return changed


## Recomputes the per-tile mean from the stored edge values (after restore).
func rebuild_tile_congestion() -> void:
	_tile_congestion.fill(0.0)
	for k in edges:
		var edge: EdgeDelta = edges[k]
		var id_a := _id(edge.a)
		var id_b := _id(edge.b)
		_tile_congestion[id_a] += edge.congestion / float(_degree[id_a])
		_tile_congestion[id_b] += edge.congestion / float(_degree[id_b])


## Edges touching the tile at (x, y). At most four.
func incident(x: int, y: int) -> Array:
	return incident_by_id(y * SIZE + x)


func incident_by_id(id: int) -> Array:
	var found: Array = []
	var east = _east[id]
	if east != null:
		found.append(east)
	var south = _south[id]
	if south != null:
		found.append(south)
	if id % SIZE > 0:
		var west = _east[id - 1]
		if west != null:
			found.append(west)
	if id >= SIZE:
		var north = _south[id - SIZE]
		if north != null:
			found.append(north)
	return found


## Copy-on-write views for the growth pass; read only.
func degree_array() -> PackedInt32Array:
	return _degree


func tile_congestion_array() -> PackedFloat32Array:
	return _tile_congestion


func _insert(k: String, edge: EdgeDelta) -> void:
	edges[k] = edge
	var id_a := _id(edge.a)
	var id_b := _id(edge.b)
	if edge.a.y == edge.b.y:
		_east[id_a] = edge
	else:
		_south[id_a] = edge
	_degree[id_a] += 1
	_degree[id_b] += 1
	_far[id_a] += _tier[id_b]
	_far[id_b] += _tier[id_a]


func _refresh_tile_congestion(id: int) -> void:
	var count := _degree[id]
	if count == 0:
		_tile_congestion[id] = 0.0
		return
	var sum := 0.0
	for edge in incident_by_id(id):
		sum += edge.congestion
	_tile_congestion[id] = sum / float(count)


static func _id(point: Vector2i) -> int:
	return point.y * SIZE + point.x

extends RefCounted

## Orthogonal road edges, per-tile road access, and the local congestion model.
##
## edges is the authoritative Dictionary edge key → EdgeDelta (ordered endpoints);
## WorldState exposes it unchanged for snapshots and the save. Internally every
## edge also sits in one of two slot arrays indexed by its west / north tile
## (_east for horizontal, _south for vertical), so the edges touching a tile are
## four array reads and no string keys. A tile "has a road" when its degree is > 0.
##
## Congestion of an edge = load / CONGESTION_CAPACITY clamped to 1, where
## load = tier(a) + tier(b) + ½ Σ over the edges sharing an endpoint of (tier of
## their two ends). Owners are never consulted. With far(t) = Σ over t's edges of
## the tier at the other end, the same load is
## ½ (deg(a) tier(a) + deg(b) tier(b) + far(a) + far(b)), which is what resolve()
## evaluates in O(1) per edge; far() is kept current by set_tier / add / remove.
##
## Two values per edge: the raw ratio feeds the growth model (tile_congestion() is
## the mean over a tile's incident edges), and EdgeDelta.congestion carries the
## same ratio quantized to 1/FIELD_QUANT for the wire and the save. A
## CongestionAlert goes out exactly when the quantized value moves. Reading the raw
## value for satisfaction keeps a street's growth from hinging on which side of a
## 1/8 step the rounding lands.
##
## Reference loads (tier-2 buildings, T = tier, deg = incident edges):
##   two buildings alone on one edge                       4
##   lot hanging off a bare street tile (comb street)      3   street tile deg 4
##   tier-1 latecomer between two tier-2 on a corridor     6.5 all deg 2
##   corridor interior, every tile tier 2                  8
##   four-way junction tile among tier-2 neighbours        11.5
##   interior of a fully roaded tier-2 grid                16
## set_tier() and add()/remove() mark the tiles whose edges can change; resolve()
## recomputes only those edges.

var edges: Dictionary = {}

var _east: Array = []
var _south: Array = []
## Raw (unquantized) congestion per slot, parallel to _east / _south.
var _raw_east: PackedFloat32Array = PackedFloat32Array()
var _raw_south: PackedFloat32Array = PackedFloat32Array()
var _degree: PackedInt32Array = PackedInt32Array()
var _tier: PackedInt32Array = PackedInt32Array()
var _far: PackedInt32Array = PackedInt32Array()
## Mean raw congestion over a tile's incident edges.
var _tile_congestion: PackedFloat32Array = PackedFloat32Array()
var _dirty_tiles: Dictionary = {}

const SIZE := SliceConstants.MAP_SIZE
const FieldQuant = preload("res://server/sim/field_quant.gd")


func _init() -> void:
	var count := SIZE * SIZE
	_east.resize(count)
	_south.resize(count)
	_raw_east.resize(count)
	_raw_east.fill(0.0)
	_raw_south.resize(count)
	_raw_south.fill(0.0)
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


## Raw load of an edge from the tiers at and around its endpoints (see header).
static func load_of(deg_a: int, tier_a: int, far_a: int, deg_b: int, tier_b: int, far_b: int) -> float:
	return 0.5 * float(deg_a * tier_a + deg_b * tier_b + far_a + far_b)


func find(a: Vector2i, b: Vector2i) -> EdgeDelta:
	return edges.get(key(a, b))


func has_road(id: int) -> bool:
	return _degree[id] > 0


func degree(id: int) -> int:
	return _degree[id]


## Mean raw congestion of the tile's incident edges, 0 without a road.
func tile_congestion(id: int) -> float:
	return _tile_congestion[id]


## Raw congestion of one edge; 0 when it does not exist.
func raw_congestion(a: Vector2i, b: Vector2i) -> float:
	var edge := find(a, b)
	if edge == null:
		return 0.0
	return _raw_of(edge)


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
		_raw_east[id_a] = 0.0
	else:
		_south[id_a] = null
		_raw_south[id_a] = 0.0
	_degree[id_a] -= 1
	_degree[id_b] -= 1
	_far[id_a] -= _tier[id_b]
	_far[id_b] -= _tier[id_a]
	_dirty_tiles[id_a] = true
	_dirty_tiles[id_b] = true
	return true


## Inserts a saved edge without marking anything dirty. Capacity and congestion
## are derived state: call recompute_all() once every edge and tier is restored.
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
	for id in _dirty_tiles:
		endpoints[id] = true
		if _degree[id] == 0:
			continue
		# The four slots an edge of this tile can sit in: its own east and south, the
		# west neighbour's east, the north neighbour's south.
		_resolve_slot(id, true, inv_capacity, done, endpoints, changed)
		_resolve_slot(id, false, inv_capacity, done, endpoints, changed)
		if id % SIZE > 0:
			_resolve_slot(id - 1, true, inv_capacity, done, endpoints, changed)
		if id >= SIZE:
			_resolve_slot(id - SIZE, false, inv_capacity, done, endpoints, changed)
	for id in endpoints:
		_refresh_tile_congestion(id)
	_dirty_tiles.clear()
	return changed


func _resolve_slot(slot: int, east: bool, inv_capacity: float, done: Dictionary, endpoints: Dictionary, changed: Array) -> void:
	var edge = _east[slot] if east else _south[slot]
	if edge == null:
		return
	var key := slot * 2 + (0 if east else 1)
	if done.has(key):
		return
	done[key] = true
	var id_b := slot + 1 if east else slot + SIZE
	var load := load_of(_degree[slot], _tier[slot], _far[slot], _degree[id_b], _tier[id_b], _far[id_b])
	var raw := clampf(load * inv_capacity, 0.0, 1.0)
	if east:
		_raw_east[slot] = raw
	else:
		_raw_south[slot] = raw
	endpoints[id_b] = true
	var next := FieldQuant.snap(raw)
	if next != edge.congestion:
		edge.congestion = next
		changed.append(edge)


## Restore path: every edge's capacity, raw and quantized congestion, and every
## tile mean from the current tiers. Nothing is reported; a save made under the
## same rules comes back with the values it stored, an older save is corrected.
func recompute_all() -> void:
	for k in edges:
		var edge: EdgeDelta = edges[k]
		edge.capacity = SliceConstants.CONGESTION_CAPACITY
		_dirty_tiles[_id(edge.a)] = true
		_dirty_tiles[_id(edge.b)] = true
	resolve()


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
		_raw_east[id_a] = 0.0
	else:
		_south[id_a] = edge
		_raw_south[id_a] = 0.0
	_degree[id_a] += 1
	_degree[id_b] += 1
	_far[id_a] += _tier[id_b]
	_far[id_b] += _tier[id_a]


func _raw_of(edge: EdgeDelta) -> float:
	var slot := _id(edge.a)
	if edge.a.y == edge.b.y:
		return _raw_east[slot]
	return _raw_south[slot]


## Mean of the raw slots around the tile. Slots without an edge hold 0 (reset on
## remove), so no null checks are needed.
func _refresh_tile_congestion(id: int) -> void:
	var count := _degree[id]
	if count == 0:
		_tile_congestion[id] = 0.0
		return
	var sum := _raw_east[id] + _raw_south[id]
	if id % SIZE > 0:
		sum += _raw_east[id - 1]
	if id >= SIZE:
		sum += _raw_south[id - SIZE]
	_tile_congestion[id] = sum / float(count)


static func _id(point: Vector2i) -> int:
	return point.y * SIZE + point.x

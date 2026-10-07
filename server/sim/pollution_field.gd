extends RefCounted

## Pollution field over the whole map, maintained incrementally.
##
## Every industrial building emits tier + 1 units. A unit spreads over the
## Manhattan diamond of radius POLLUTION_RADIUS with a linear kernel
## w(d) = POLLUTION_RADIUS + 1 − d, normalized so the kernel sums to 1 over the
## full diamond (weight_total). A tile's pollution is Σ emission × w(d) / weight_total,
## clamped to 1: one unit concentrated on a single tile would pollute it fully, and
## one max-tier factory alone peaks at 3 × w(0) / weight_total on its own tile.
## Owners are never consulted; the field crosses faction borders. Mass is stored as
## integers so adding and removing sources never drifts.
##
## set_emission() applies the delta to the diamond and records the touched tiles;
## WorldState drains take_dirty() each tick and requantizes only those.

var weight_total: int = 0

var _mass: PackedInt32Array = PackedInt32Array()
var _emission: PackedInt32Array = PackedInt32Array()
var _dirty: Dictionary = {}
var _dx: PackedInt32Array = PackedInt32Array()
var _dy: PackedInt32Array = PackedInt32Array()
var _w: PackedInt32Array = PackedInt32Array()


func _init() -> void:
	var count := SliceConstants.MAP_SIZE * SliceConstants.MAP_SIZE
	_mass.resize(count)
	_mass.fill(0)
	_emission.resize(count)
	_emission.fill(0)
	var radius := SliceConstants.POLLUTION_RADIUS
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var d := absi(dx) + absi(dy)
			if d > radius:
				continue
			_dx.append(dx)
			_dy.append(dy)
			_w.append(radius + 1 - d)
			weight_total += radius + 1 - d


## Emission for a tile: tier + 1 for an industrial building, 0 otherwise. Applies
## only the change against the previous emission.
func set_emission(id: int, emission: int) -> void:
	var delta := emission - _emission[id]
	if delta == 0:
		return
	_emission[id] = emission
	var size := SliceConstants.MAP_SIZE
	var x := id % size
	var y := int(id / size)
	for i in _dx.size():
		var nx := x + _dx[i]
		var ny := y + _dy[i]
		if nx < 0 or ny < 0 or nx >= size or ny >= size:
			continue
		var nid := ny * size + nx
		_mass[nid] += delta * _w[i]
		_dirty[nid] = true


func emission(id: int) -> int:
	return _emission[id]


func mass(id: int) -> int:
	return _mass[id]


## Raw 0–1 value.
func value(id: int) -> float:
	return minf(1.0, float(_mass[id]) / float(weight_total))


## Value quantized to 1/FIELD_QUANT, computed in integers.
func quantized(id: int) -> float:
	return FieldQuant.snap_ratio(_mass[id], weight_total)


## Tiles whose mass changed since the last call. Clears the record.
func take_dirty() -> Array:
	var ids := _dirty.keys()
	_dirty.clear()
	return ids


## Copy-on-write view for the growth pass; read only.
func mass_array() -> PackedInt32Array:
	return _mass


const FieldQuant = preload("res://server/sim/field_quant.gd")

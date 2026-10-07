extends RefCounted
## Adapter from one 8x8 interest block of ClientSession data to the shape the live builders
## read (the showcase CityData interface: tile(), road_v / road_h, junction_arms, tile_roads).
## The window is the block plus its orthogonal 1-tile ring: ring tiles come from the
## neighbouring BlockView snapshots, edges from this block's snapshot plus the four orthogonal
## neighbours' snapshots, so junction arms on the block boundary are complete.
##
## Seam rules (one drawer per piece, consistent across blocks):
##   segment (a,b)   drawn by a's block; by b's block when a's block is not subscribed
##   corner (i,j)    drawn by the block of the first subscribed tile among
##                   (i-1,j-1), (i,j-1), (i-1,j), (i,j)
##   border a|b      same as a segment between the two tiles

const SC := preload("res://shared/slice_constants.gd")
const BLOCK := SC.INTEREST_BLOCK

var key: String = ""
var bx: int = 0
var by: int = 0
var x0: int = 0
var y0: int = 0
## 64 TileDelta, index (y - y0) * BLOCK + (x - x0).
var tiles: Array = []
## Ring tiles by tile id (orthogonal neighbours' snapshots); missing entries read as neutral.
var ring: Dictionary = {}
## edge_key -> EdgeDelta, own block plus the four orthogonal neighbours.
var edges: Dictionary = {}
## block key -> bool for the 3x3 neighbourhood.
var subscribed: Dictionary = {}

var _neutral: TileDelta = TileDelta.new()
## Road presence over the window, indexed by index_edges(): lines x0-1 .. x0+BLOCK+1 (WLINES)
## by rows / columns y0-1 .. y0+BLOCK (WCELLS).
const WLINES := BLOCK + 3
const WCELLS := BLOCK + 2
var _vr := PackedByteArray()
var _hr := PackedByteArray()


func setup(p_bx: int, p_by: int) -> void:
	bx = p_bx
	by = p_by
	x0 = bx * BLOCK
	y0 = by * BLOCK
	key = "%d,%d" % [bx, by]


func in_block(x: int, y: int) -> bool:
	return x >= x0 and y >= y0 and x < x0 + BLOCK and y < y0 + BLOCK


func tile(x: int, y: int) -> TileDelta:
	if in_block(x, y):
		return tiles[(y - y0) * BLOCK + (x - x0)]
	var id := SC.tile_id(x, y)
	if ring.has(id):
		return ring[id]
	return _neutral


static func edge_key(ax: int, ay: int, bx_: int, by_: int) -> String:
	return "%d,%d:%d,%d" % [ax, ay, bx_, by_]


## Builds the road presence arrays from `edges`; call once after the edge dictionary is filled.
func index_edges() -> void:
	_vr.resize(WLINES * WCELLS)
	_hr.resize(WLINES * WCELLS)
	_vr.fill(0)
	_hr.fill(0)
	for key in edges:
		var e: EdgeDelta = edges[key]
		if e.a.y == e.b.y:
			var i := maxi(e.a.x, e.b.x) - (x0 - 1)
			var z := e.a.y - (y0 - 1)
			if i >= 0 and i < WLINES and z >= 0 and z < WCELLS:
				_vr[i * WCELLS + z] = 1
		else:
			var j := maxi(e.a.y, e.b.y) - (y0 - 1)
			var x := e.a.x - (x0 - 1)
			if j >= 0 and j < WLINES and x >= 0 and x < WCELLS:
				_hr[j * WCELLS + x] = 1


## Vertical border line x = i between tiles (i-1, z) and (i, z).
func road_v(i: int, z: int) -> bool:
	var li := i - (x0 - 1)
	var lz := z - (y0 - 1)
	if li < 0 or li >= WLINES or lz < 0 or lz >= WCELLS:
		return false
	return _vr[li * WCELLS + lz] == 1


## Horizontal border line z = j between tiles (x, j-1) and (x, j).
func road_h(x: int, j: int) -> bool:
	var lj := j - (y0 - 1)
	var lx := x - (x0 - 1)
	if lj < 0 or lj >= WLINES or lx < 0 or lx >= WCELLS:
		return false
	return _hr[lj * WCELLS + lx] == 1


func edge_v(i: int, z: int) -> EdgeDelta:
	return edges.get(edge_key(i - 1, z, i, z))


func edge_h(x: int, j: int) -> EdgeDelta:
	return edges.get(edge_key(x, j - 1, x, j))


## Bit mask of roads around corner (i,j): 1=N 2=E 4=S 8=W.
func junction_arms(i: int, j: int) -> int:
	var m := 0
	if road_v(i, j - 1): m |= 1
	if road_h(i, j): m |= 2
	if road_v(i, j): m |= 4
	if road_h(i - 1, j): m |= 8
	return m


func straight(i: int, j: int) -> bool:
	var a := junction_arms(i, j)
	return a == 5 or a == 10


## Bit mask of the tile sides that border a road: 1=N 2=E 4=S 8=W.
func tile_roads(x: int, y: int) -> int:
	var m := 0
	if road_h(x, y): m |= 1
	if road_v(x + 1, y): m |= 2
	if road_h(x, y + 1): m |= 4
	if road_v(x, y): m |= 8
	return m


static func block_key_of(x: int, y: int) -> String:
	return "%d,%d" % [int(x / BLOCK), int(y / BLOCK)]


func tile_subscribed(x: int, y: int) -> bool:
	if not SC.in_map(x, y):
		return false
	return subscribed.get(block_key_of(x, y), false)


## True when this block draws the piece between ordered tiles a (first) and b.
func owns_edge(ax: int, ay: int, bx_: int, by_: int) -> bool:
	if in_block(ax, ay):
		return true
	if not tile_subscribed(ax, ay) and in_block(bx_, by_):
		return true
	return false


## Vertical segment on line i at row z: edge (i-1,z)-(i,z).
func owns_segment_v(i: int, z: int) -> bool:
	return owns_edge(i - 1, z, i, z)


## Horizontal segment on line j at column x: edge (x,j-1)-(x,j).
func owns_segment_h(x: int, j: int) -> bool:
	return owns_edge(x, j - 1, x, j)


## True when this block draws the junction at corner (i, j).
func owns_corner(i: int, j: int) -> bool:
	for cell in [Vector2i(i - 1, j - 1), Vector2i(i, j - 1), Vector2i(i - 1, j), Vector2i(i, j)]:
		if not SC.in_map(cell.x, cell.y):
			continue
		if tile_subscribed(cell.x, cell.y):
			return in_block(cell.x, cell.y)
	return false

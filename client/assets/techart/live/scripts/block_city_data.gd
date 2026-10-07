extends RefCounted
## Adapter from one 8x8 interest block of ClientSession data to the shape the live builders
## read (the showcase CityData interface: tile(), road_v / road_h, junction_arms, tile_roads).
##
## Road graph to street geometry. A game edge joins two orthogonal tiles (docs/briefs/
## world-vertical-slice.md: tiles are the nodes of the road graph). Each tile's node is drawn at
## its south-east corner, so edge (a, b) is the street segment between corners a+(1,1) and
## b+(1,1): a chain of edges along a row is one continuous street, a T in the graph is a T
## junction at the corner, a dead end stops at a corner. Streets run along lot borders exactly as
## in the showcase (lots inset by H), the tile west / north of a street fronts it.
##   vertical game edge (x,y)-(x,y+1)   -> road_v(x+1, y+1): line x+1, rows y+1
##   horizontal game edge (x,y)-(x+1,y) -> road_h(x+1, y+1): line y+1, column x+1
##   corner (i, j)                      -> node of tile (i-1, j-1); its arms are that tile's edges
##
## The window is the block plus a ring: ring tiles (orthogonal neighbours' snapshots) for the
## territory border, edges of all eight neighbours for seam junctions and lot pads.
##
## Seam rules (one drawer per piece, identical in every block):
##   segment of edge (a,b)   a's block; b's block when a's block is not subscribed
##   corner (i,j)            the node tile's block when subscribed; else the first subscribed
##                           tile among the other three corner tiles; else, for an arm in
##                           N E S W order, that arm's segment owner

const SC := preload("res://shared/slice_constants.gd")
const BLOCK := SC.INTEREST_BLOCK
## Window: lines x0-1 .. x0+BLOCK+2 (WLINES), rows / columns y0-1 .. y0+BLOCK+1 (WCELLS).
const WLINES := BLOCK + 4
const WCELLS := BLOCK + 3

var key: String = ""
var bx: int = 0
var by: int = 0
var x0: int = 0
var y0: int = 0
## 64 TileDelta, index (y - y0) * BLOCK + (x - x0).
var tiles: Array = []
## Ring tiles by tile id (orthogonal neighbours' snapshots); missing entries read as neutral.
var ring: Dictionary = {}
## edge_key -> EdgeDelta, own block plus the neighbours' edges inside the window.
var edges: Dictionary = {}
## block key -> bool for the 3x3 neighbourhood.
var subscribed: Dictionary = {}

var _neutral: TileDelta = TileDelta.new()
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


## True when a tile coordinate is close enough to the block for its edges to matter here.
func near_block(p: Vector2i) -> bool:
	return p.x >= x0 - 2 and p.y >= y0 - 2 and p.x <= x0 + BLOCK + 1 and p.y <= y0 + BLOCK + 1


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
	for ekey in edges:
		var e: EdgeDelta = edges[ekey]
		if e.a.x == e.b.x:
			# vertical game edge -> vertical street segment on line x+1 at row min(y)+1
			var i := e.a.x + 1 - (x0 - 1)
			var z := mini(e.a.y, e.b.y) + 1 - (y0 - 1)
			if i >= 0 and i < WLINES and z >= 0 and z < WCELLS:
				_vr[i * WCELLS + z] = 1
		else:
			var j := e.a.y + 1 - (y0 - 1)
			var x := mini(e.a.x, e.b.x) + 1 - (x0 - 1)
			if j >= 0 and j < WLINES and x >= 0 and x < WCELLS:
				_hr[j * WCELLS + x] = 1


## Street segment on vertical line x = i spanning row z (between tiles (i-1, z) and (i, z)).
func road_v(i: int, z: int) -> bool:
	var li := i - (x0 - 1)
	var lz := z - (y0 - 1)
	if li < 0 or li >= WLINES or lz < 0 or lz >= WCELLS:
		return false
	return _vr[li * WCELLS + lz] == 1


## Street segment on horizontal line z = j spanning column x (between tiles (x, j-1) and (x, j)).
func road_h(x: int, j: int) -> bool:
	var lj := j - (y0 - 1)
	var lx := x - (x0 - 1)
	if lj < 0 or lj >= WLINES or lx < 0 or lx >= WCELLS:
		return false
	return _hr[lj * WCELLS + lx] == 1


## Game edge behind a vertical street segment: tiles (i-1, z-1) and (i-1, z).
func edge_v(i: int, z: int) -> EdgeDelta:
	return edges.get(edge_key(i - 1, z - 1, i - 1, z))


## Game edge behind a horizontal street segment: tiles (x-1, j-1) and (x, j-1).
func edge_h(x: int, j: int) -> EdgeDelta:
	return edges.get(edge_key(x - 1, j - 1, x, j - 1))


## Bit mask of streets around corner (i,j): 1=N 2=E 4=S 8=W. These are the edges of tile (i-1, j-1).
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


## Bit mask of the tile sides that border a street: 1=N 2=E 4=S 8=W.
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


## True when this block draws the piece of game edge a (first) - b.
func owns_edge(ax: int, ay: int, bx_: int, by_: int) -> bool:
	if in_block(ax, ay):
		return true
	if not tile_subscribed(ax, ay) and in_block(bx_, by_):
		return true
	return false


## Vertical street segment on line i at row z.
func owns_segment_v(i: int, z: int) -> bool:
	return owns_edge(i - 1, z - 1, i - 1, z)


## Horizontal street segment on line j at column x.
func owns_segment_h(x: int, j: int) -> bool:
	return owns_edge(x - 1, j - 1, x, j - 1)


## True when this block draws the junction at corner (i, j).
func owns_corner(i: int, j: int) -> bool:
	for cell in [Vector2i(i - 1, j - 1), Vector2i(i, j - 1), Vector2i(i - 1, j), Vector2i(i, j)]:
		if not SC.in_map(cell.x, cell.y):
			continue
		if tile_subscribed(cell.x, cell.y):
			return in_block(cell.x, cell.y)
	# no corner tile is subscribed: the first present arm's segment owner draws the dead end
	if road_v(i, j - 1):
		return owns_segment_v(i, j - 1)
	if road_h(i, j):
		return owns_segment_h(i, j)
	if road_v(i, j):
		return owns_segment_v(i, j)
	if road_h(i - 1, j):
		return owns_segment_h(i - 1, j)
	return false

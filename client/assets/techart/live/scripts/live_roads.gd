extends RefCounted
## Roads, sidewalks, curbs and lot pads for one block window. Adapted from showcase
## road_builder.gd: the same street section (carriageway, parking lanes, sidewalks, curb
## returns, quarter-disc corners, crosswalks on 3+ way junctions), but every piece is drawn by
## exactly one block (BlockCityData seam rules). Straight-through corners still merge into runs;
## a run that continues into a neighbouring block is cut at the corner line without a junction
## square, and the live road shader keeps the lane paint continuous across the cut.

const Cfg := preload("res://client/assets/techart/live/scripts/live_cfg.gd")
const LB := preload("res://client/assets/techart/live/scripts/live_batch.gd")
const SC := preload("res://shared/slice_constants.gd")

const C := Cfg.C
const H := Cfg.H
const S := Cfg.S
const CH := Cfg.CURB_H
const P := Cfg.P
const FILLET_SEGS := 6
const DIRV := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]

var D
var B: Dictionary
## Junction geometry cache owned by BlockView: "i,j" -> {"arms": int, "batches": Dictionary}.
## Rebuilt corners are looked up by arms; corners no longer drawn are dropped.
var junction_cache: Dictionary = {}
## {vertical, line, a0, a1} with a0 < a1 the world coordinate span of the carriageway piece
## along its axis, and `cross` the world coordinate of the centre line; used by live_props.
var runs: Array = []
## {i, j, pos: Vector3, arms}
var junctions: Array = []
## Edge keys of the segments this block drew (view check: a seam edge is drawn once).
var segments_drawn: Array[String] = []
## Corners this block drew junction geometry for.
var corners_drawn: Array[Vector2i] = []


func _init(data, batches: Dictionary, p_junction_cache: Dictionary = {}) -> void:
	D = data
	B = batches
	junction_cache = p_junction_cache


func b(key: String) -> RefCounted:
	if not B.has(key):
		B[key] = LB.new()
	return B[key]


static func _count_bits(m: int) -> int:
	return (m & 1) + ((m >> 1) & 1) + ((m >> 2) & 1) + ((m >> 3) & 1)


## Carriageway runs and junctions. Lot pads are per tile (tile_pad) so BlockView can cache them.
func build() -> void:
	_runs()
	_junctions()


# ---------------------------------------------------------------- runs (segments)
## Chains of owned segments through straight corners, per border line.
func _runs() -> void:
	var x0: int = D.x0
	var y0: int = D.y0
	# vertical lines x = i: segments at rows z; owned ones have z inside the block
	for i in range(x0, x0 + D.BLOCK + 1):
		var z := y0
		while z < y0 + D.BLOCK:
			if D.road_v(i, z) and D.owns_segment_v(i, z):
				var ze := z
				while ze + 1 < y0 + D.BLOCK and D.straight(i, ze + 1) and D.road_v(i, ze + 1) and D.owns_segment_v(i, ze + 1):
					ze += 1
				_emit_run(i, z, ze, true)
				z = ze + 1
			else:
				z += 1
	for j in range(y0, y0 + D.BLOCK + 1):
		var x := x0
		while x < x0 + D.BLOCK:
			if D.road_h(x, j) and D.owns_segment_h(x, j):
				var xe := x
				while xe + 1 < x0 + D.BLOCK and D.straight(xe + 1, j) and D.road_h(xe + 1, j) and D.owns_segment_h(xe + 1, j):
					xe += 1
				_emit_run(j, x, xe, false)
				x = xe + 1
			else:
				x += 1


## line: the border line index; s0..s1 the tile rows (vertical) or columns (horizontal) covered.
func _emit_run(line: int, s0: int, s1: int, vertical: bool) -> void:
	var arms_start: int = D.junction_arms(line, s0) if vertical else D.junction_arms(s0, line)
	var arms_end: int = D.junction_arms(line, s1 + 1) if vertical else D.junction_arms(s1 + 1, line)
	var straight_start := arms_start == 5 or arms_start == 10
	var straight_end := arms_end == 5 or arms_end == 10
	# a straight corner at a chain end means the next segment belongs to a neighbour: cut at the line
	var inset_s := 0.0 if straight_start else H
	var inset_e := 0.0 if straight_end else H
	var flags := 0
	if not straight_start and _count_bits(arms_start) >= 3:
		flags |= 1
	if not straight_end and _count_bits(arms_end) >= 3:
		flags |= 2
	# centre line style: dashed white on even lines, none on odd ones (every game edge has one capacity)
	var style := 0.0 if line % 2 == 0 else 0.5
	var packed := float(flags + (4 if vertical else 0)) / 7.0
	var col := Color(0.0, 0.0, packed, style)
	var ra := b("road")
	var sw := b("sidewalk")
	var cb := b("curb")
	var a0 := s0 * P + inset_s
	var a1 := (s1 + 1) * P - inset_e
	var L := a1 - a0
	var cross := line * P
	runs.append({"vertical": vertical, "line": line, "a0": a0, "a1": a1, "cross": cross, "s0": s0, "s1": s1})
	for s in range(s0, s1 + 1):
		if vertical:
			segments_drawn.append(D.edge_key(line - 1, s, line, s))
		else:
			segments_drawn.append(D.edge_key(s, line - 1, s, line))
	if vertical:
		var xc := cross
		# t = -(x - xc): right-hand side for +z travel
		ra.quad(Vector3(xc - C, 0, a0), Vector3(xc + C, 0, a0), Vector3(xc + C, 0, a1), Vector3(xc - C, 0, a1), Vector3.UP,
			Vector2(0, L), Vector2(0, L), Vector2(L, 0), Vector2(L, 0), col, Vector2.ZERO, Color(0, 0, 0, 0),
			[Vector2(C, 0), Vector2(-C, 0), Vector2(-C, 0), Vector2(C, 0)])
		for side in [-1.0, 1.0]:
			var xa: float = xc + side * C
			var xb: float = xc + side * H
			sw.quad(Vector3(xa, CH, a0), Vector3(xb, CH, a0), Vector3(xb, CH, a1), Vector3(xa, CH, a1), Vector3.UP,
				Vector2(xa, a0), Vector2(xb, a0), Vector2(xb, a1), Vector2(xa, a1), Color.WHITE, Vector2.ZERO, Color(0, 0, 0, 0),
				[Vector2(0, S), Vector2(S, 0), Vector2(S, 0), Vector2(0, S)])
			var nrm := Vector3(-side, 0, 0)
			cb.quad(Vector3(xa, CH, a0), Vector3(xa, CH, a1), Vector3(xa, 0, a1), Vector3(xa, 0, a0), nrm,
				Vector2(a0, -CH), Vector2(a1, -CH), Vector2(a1, 0), Vector2(a0, 0))
	else:
		var zc := cross
		# t = +(z - zc): right-hand side for +x travel
		ra.quad(Vector3(a0, 0, zc - C), Vector3(a1, 0, zc - C), Vector3(a1, 0, zc + C), Vector3(a0, 0, zc + C), Vector3.UP,
			Vector2(0, L), Vector2(L, 0), Vector2(L, 0), Vector2(0, L), col, Vector2.ZERO, Color(0, 0, 0, 0),
			[Vector2(-C, 0), Vector2(-C, 0), Vector2(C, 0), Vector2(C, 0)])
		for side in [-1.0, 1.0]:
			var za: float = zc + side * C
			var zb: float = zc + side * H
			sw.quad(Vector3(a0, CH, za), Vector3(a1, CH, za), Vector3(a1, CH, zb), Vector3(a0, CH, zb), Vector3.UP,
				Vector2(a0, za), Vector2(a1, za), Vector2(a1, zb), Vector2(a0, zb), Color.WHITE, Vector2.ZERO, Color(0, 0, 0, 0),
				[Vector2(0, S), Vector2(0, S), Vector2(S, 0), Vector2(S, 0)])
			var nrm := Vector3(0, 0, -side)
			cb.quad(Vector3(a0, CH, za), Vector3(a1, CH, za), Vector3(a1, 0, za), Vector3(a0, 0, za), nrm,
				Vector2(a0, -CH), Vector2(a1, -CH), Vector2(a1, 0), Vector2(a0, 0))


# ---------------------------------------------------------------- junctions
func _junctions() -> void:
	var kept := {}
	for j in range(D.y0, D.y0 + D.BLOCK + 1):
		for i in range(D.x0, D.x0 + D.BLOCK + 1):
			var arms: int = D.junction_arms(i, j)
			if arms == 0 or arms == 5 or arms == 10:
				continue
			if not D.owns_corner(i, j):
				continue
			var ckey := "%d,%d" % [i, j]
			var entry = junction_cache.get(ckey)
			if entry == null or entry["arms"] != arms:
				var batches := {}
				_emit_junction(i, j, arms, batches)
				entry = {"arms": arms, "batches": batches}
			kept[ckey] = entry
			junctions.append({"i": i, "j": j, "pos": Cfg.corner(i, j), "arms": arms})
			corners_drawn.append(Vector2i(i, j))
			var batches: Dictionary = entry["batches"]
			for k in batches:
				b(k).append(batches[k])
	junction_cache.clear()
	junction_cache.merge(kept)


func _w(cx: float, cz: float, p: Vector2, y: float) -> Vector3:
	return Vector3(cx + p.x, y, cz + p.y)


func _wuv(cx: float, cz: float, p: Vector2) -> Vector2:
	return Vector2(cx + p.x, cz + p.y)


static func _bt(batches: Dictionary, key: String) -> RefCounted:
	if not batches.has(key):
		batches[key] = LB.new()
	return batches[key]


## One junction into `batches` (world space), so BlockView can cache it per corner.
func _emit_junction(i: int, j: int, arms: int, batches: Dictionary) -> void:
	var c := Cfg.corner(i, j)
	var cx := c.x
	var cz := c.z
	var ra := _bt(batches, "road")
	var sw := _bt(batches, "sidewalk")
	var cb := _bt(batches, "curb")
	var col := Color(1.0, float(arms) / 15.0, 0.0, 0.0)
	_asph_quad(ra, cx, cz, Vector2(-C, -C), Vector2(C, -C), Vector2(C, C), Vector2(-C, C), col)
	for d in 4:
		var v: Vector2 = DIRV[d]
		var l: Vector2 = DIRV[(d + 1) % 4]
		var present := (arms >> d) & 1 == 1
		var p0: Vector2 = v * C - l * C
		var p1: Vector2 = v * C + l * C
		var p2: Vector2 = v * H + l * C
		var p3: Vector2 = v * H - l * C
		if present:
			_asph_quad(ra, cx, cz, p0, p1, p2, p3, col)
		else:
			var n3 := Vector3(-v.x, 0, -v.y)
			sw.quad(_w(cx, cz, p0, CH), _w(cx, cz, p1, CH), _w(cx, cz, p2, CH), _w(cx, cz, p3, CH), Vector3.UP,
				_wuv(cx, cz, p0), _wuv(cx, cz, p1), _wuv(cx, cz, p2), _wuv(cx, cz, p3), Color.WHITE, Vector2.ZERO, Color(0, 0, 0, 0),
				[Vector2(0, S), Vector2(0, S), Vector2(S, 0), Vector2(S, 0)])
			cb.quad(_w(cx, cz, p0, CH), _w(cx, cz, p1, CH), _w(cx, cz, p1, 0), _w(cx, cz, p0, 0), n3,
				Vector2(0, -CH), Vector2(2 * C, -CH), Vector2(2 * C, 0), Vector2(0, 0))
	for k in 4:
		var vk: Vector2 = DIRV[k]
		var vk1: Vector2 = DIRV[(k + 1) % 4]
		var pk := (arms >> k) & 1 == 1
		var pk1 := (arms >> ((k + 1) % 4)) & 1 == 1
		var pc: Vector2 = vk * C + vk1 * C
		var pa: Vector2 = vk * H + vk1 * C
		var pb: Vector2 = vk * C + vk1 * H
		var pk_far: Vector2 = vk * H + vk1 * H
		if pk and pk1:
			var arc: Array = []
			for s in FILLET_SEGS + 1:
				var phi := (PI * 0.5) * float(s) / float(FILLET_SEGS)
				arc.append(vk * (H - S * sin(phi)) + vk1 * (H - S * cos(phi)))
			for s in FILLET_SEGS:
				var q0: Vector2 = arc[s]
				var q1: Vector2 = arc[s + 1]
				ra.tri(_w(cx, cz, pc, 0), _w(cx, cz, q0, 0), _w(cx, cz, q1, 0), Vector3.UP,
					pc, q0, q1, col)
				sw.tri(_w(cx, cz, pk_far, CH), _w(cx, cz, q0, CH), _w(cx, cz, q1, CH), Vector3.UP,
					_wuv(cx, cz, pk_far), _wuv(cx, cz, q0), _wuv(cx, cz, q1), Color.WHITE, Vector2.ZERO, Color(0, 0, 0, 0),
					[Vector2(S, 0), Vector2(0, S), Vector2(0, S)])
				var n0: Vector2 = (q0 - pk_far).normalized()
				var n1: Vector2 = (q1 - pk_far).normalized()
				var nm: Vector2 = ((n0 + n1) * 0.5).normalized()
				cb.quad(_w(cx, cz, q0, CH), _w(cx, cz, q1, CH), _w(cx, cz, q1, 0), _w(cx, cz, q0, 0), Vector3(nm.x, 0, nm.y),
					Vector2(float(s), -CH), Vector2(float(s + 1), -CH), Vector2(float(s + 1), 0), Vector2(float(s), 0))
		else:
			sw.quad(_w(cx, cz, pc, CH), _w(cx, cz, pa, CH), _w(cx, cz, pk_far, CH), _w(cx, cz, pb, CH), Vector3.UP,
				_wuv(cx, cz, pc), _wuv(cx, cz, pa), _wuv(cx, cz, pk_far), _wuv(cx, cz, pb), Color.WHITE, Vector2.ZERO, Color(0, 0, 0, 0),
				[Vector2(S, S), Vector2(S, S), Vector2(S, S), Vector2(S, S)])
			if pk:
				cb.quad(_w(cx, cz, pc, CH), _w(cx, cz, pa, CH), _w(cx, cz, pa, 0), _w(cx, cz, pc, 0), Vector3(-vk1.x, 0, -vk1.y),
					Vector2(0, -CH), Vector2(S, -CH), Vector2(S, 0), Vector2(0, 0))
			if pk1:
				cb.quad(_w(cx, cz, pc, CH), _w(cx, cz, pb, CH), _w(cx, cz, pb, 0), _w(cx, cz, pc, 0), Vector3(-vk.x, 0, -vk.y),
					Vector2(0, -CH), Vector2(S, -CH), Vector2(S, 0), Vector2(0, 0))


## Junction asphalt: UV = local metres from the corner (the shader's junction mode reads them).
func _asph_quad(ra: RefCounted, cx: float, cz: float, p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, col: Color) -> void:
	ra.quad(_w(cx, cz, p0, 0), _w(cx, cz, p1, 0), _w(cx, cz, p2, 0), _w(cx, cz, p3, 0), Vector3.UP,
		p0, p1, p2, p3, col)


# ---------------------------------------------------------------- lot pads
static func pad_key(zone: int) -> String:
	match zone:
		SC.Zone.C:
			return "paving"
		SC.Zone.I:
			return "gravel"
	return "grass"


## Bit mask of the tile's corners that carry no junction: 1=NW 2=NE 4=SW 8=SE.
static func corners_free(data, x: int, y: int) -> int:
	var m := 0
	if data.junction_arms(x, y) == 0: m |= 1
	if data.junction_arms(x + 1, y) == 0: m |= 2
	if data.junction_arms(x, y + 1) == 0: m |= 4
	if data.junction_arms(x + 1, y + 1) == 0: m |= 8
	return m


## Raised lot pad of one owned tile: the lot core, the sides without a road out to the tile
## border, and the corner squares without a junction. Appended to batches[pad_key(zone)].
static func tile_pad(t: TileDelta, roads: int, free: int, batches: Dictionary) -> void:
	if t.owner == SC.Owner.NEUTRAL:
		return
	var key := pad_key(t.zone)
	if not batches.has(key):
		batches[key] = LB.new()
	var bp: RefCounted = batches[key]
	var o := Cfg.corner(t.x, t.y)
	var pieces: Array = []
	pieces.append(Rect2(o.x + H, o.z + H, P - 2 * H, P - 2 * H))
	if roads & 1 == 0: pieces.append(Rect2(o.x + H, o.z, P - 2 * H, H))
	if roads & 4 == 0: pieces.append(Rect2(o.x + H, o.z + P - H, P - 2 * H, H))
	if roads & 8 == 0: pieces.append(Rect2(o.x, o.z + H, H, P - 2 * H))
	if roads & 2 == 0: pieces.append(Rect2(o.x + P - H, o.z + H, H, P - 2 * H))
	if free & 1: pieces.append(Rect2(o.x, o.z, H, H))
	if free & 2: pieces.append(Rect2(o.x + P - H, o.z, H, H))
	if free & 4: pieces.append(Rect2(o.x, o.z + P - H, H, H))
	if free & 8: pieces.append(Rect2(o.x + P - H, o.z + P - H, H, H))
	for r in pieces:
		var rr: Rect2 = r
		bp.rect_xz(rr.position.x, rr.position.y, rr.end.x, rr.end.y, CH, true, 1.0, Color.WHITE, Vector2.ZERO, Vector2(0, 1.0))
		bp.box(Vector3(rr.position.x, -0.12, rr.position.y), Vector3(rr.end.x, CH, rr.end.y), Color.WHITE, 0x33, 1.0)

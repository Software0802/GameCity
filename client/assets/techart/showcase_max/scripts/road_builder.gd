extends RefCounted
## Roads, sidewalks, curbs, lot pads and terrain from the edge/tile data.
## Edge (a,b) is drawn along the shared tile border. Straight-through corners merge into long runs
## so lane paint is continuous; real junctions (T, cross, L, dead end) get a core + arm cells,
## filleted curb returns, quarter-disc sidewalk corners and crosswalks on 3+ way junctions.

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")
const MB := preload("res://client/assets/techart/showcase_max/scripts/mesh_batch.gd")
const SC := preload("res://shared/slice_constants.gd")

const C := Cfg.C
const H := Cfg.H
const S := Cfg.S
const CH := Cfg.CURB_H
const FILLET_SEGS := 7

var D
var B: Dictionary
var runs: Array = []        # {vertical, c0: Vector3, c1: Vector3, L, a0: Vector3, a1: Vector3, cap}
var junctions: Array = []   # {i, j, pos: Vector3, arms: int}

func _init(data, batches: Dictionary) -> void:
	D = data
	B = batches

func b(key: String) -> RefCounted:
	if not B.has(key):
		B[key] = MB.new()
	return B[key]

static func _count_bits(m: int) -> int:
	return (m & 1) + ((m >> 1) & 1) + ((m >> 2) & 1) + ((m >> 3) & 1)

func _straight(i: int, j: int) -> bool:
	var a: int = D.junction_arms(i, j)
	return a == 5 or a == 10

func build() -> void:
	_runs()
	_junctions()
	_pads()
	_terrain()

# ---------------------------------------------------------------- runs (segments)
func _runs() -> void:
	# vertical lines x = corner(i, *): road_v(i, z)
	for i in range(1, D.n):
		var z := 0
		while z < D.n:
			if D.road_v(i, z) and not _straight(i, z):
				var ze := z
				while ze + 1 < D.n and _straight(i, ze + 1) and D.road_v(i, ze + 1):
					ze += 1
				_emit_run(i, z, ze, true)
				z = ze + 1
			else:
				z += 1
	for j in range(1, D.n):
		var x := 0
		while x < D.n:
			if D.road_h(x, j) and not _straight(x, j):
				var xe := x
				while xe + 1 < D.n and _straight(xe + 1, j) and D.road_h(xe + 1, j):
					xe += 1
				_emit_run(j, x, xe, false)
				x = xe + 1
			else:
				x += 1

func _emit_run(line: int, s0: int, s1: int, vertical: bool) -> void:
	# vertical: x = corner(line, .).x, runs along z over tiles s0..s1 ; horizontal: z = corner(., line).z along x
	var c_start: Vector3 = Cfg.corner(line, s0) if vertical else Cfg.corner(s0, line)
	var c_end: Vector3 = Cfg.corner(line, s1 + 1) if vertical else Cfg.corner(s1 + 1, line)
	var cap: int = D.vr_cap[line * D.n + s0] if vertical else D.hr_cap[line * D.n + s0]
	var style := 1.0 if cap >= 3 else (0.0 if cap == 2 else 0.5)
	var arms_start: int = D.junction_arms(line, s0) if vertical else D.junction_arms(s0, line)
	var arms_end: int = D.junction_arms(line, s1 + 1) if vertical else D.junction_arms(s1 + 1, line)
	var flags := 0
	if _count_bits(arms_start) >= 3:
		flags |= 1
	if _count_bits(arms_end) >= 3:
		flags |= 2
	var ra := b("road")
	var sw := b("sidewalk")
	var cb := b("curb")
	runs.append({"vertical": vertical, "c0": c_start, "c1": c_end, "cap": cap, "line": line, "s0": s0, "s1": s1,
		"flags": flags})
	if vertical:
		var xc := c_start.x
		var z0 := c_start.z + H
		var z1 := c_end.z - H
		var L := z1 - z0
		var col := Color(0.0, L / 64.0, float(flags) / 3.0, style)
		# t = -(x - xc): right-hand side for +z travel
		ra.quad(Vector3(xc - C, 0, z0), Vector3(xc + C, 0, z0), Vector3(xc + C, 0, z1), Vector3(xc - C, 0, z1), Vector3.UP,
			Vector2(xc - C, z0), Vector2(xc + C, z0), Vector2(xc + C, z1), Vector2(xc - C, z1), col, Vector2.ZERO, Color(0, 0, 0, 0),
			[Vector2(0, C), Vector2(0, -C), Vector2(L, -C), Vector2(L, C)])
		for side in [-1.0, 1.0]:
			var xa: float = xc + side * C
			var xb: float = xc + side * H
			sw.quad(Vector3(xa, CH, z0), Vector3(xb, CH, z0), Vector3(xb, CH, z1), Vector3(xa, CH, z1), Vector3.UP,
				Vector2(xa, z0), Vector2(xb, z0), Vector2(xb, z1), Vector2(xa, z1), Color.WHITE, Vector2.ZERO, Color(0, 0, 0, 0),
				[Vector2(0, S), Vector2(S, 0), Vector2(S, 0), Vector2(0, S)])
			# curb face toward the road
			var nrm := Vector3(-side, 0, 0)
			cb.quad(Vector3(xa, CH, z0), Vector3(xa, CH, z1), Vector3(xa, 0, z1), Vector3(xa, 0, z0), nrm,
				Vector2(z0, -CH), Vector2(z1, -CH), Vector2(z1, 0), Vector2(z0, 0))
	else:
		var zc := c_start.z
		var x0 := c_start.x + H
		var x1 := c_end.x - H
		var L := x1 - x0
		var col := Color(0.0, L / 64.0, float(flags) / 3.0, style)
		# t = +(z - zc): right-hand side for +x travel
		ra.quad(Vector3(x0, 0, zc - C), Vector3(x1, 0, zc - C), Vector3(x1, 0, zc + C), Vector3(x0, 0, zc + C), Vector3.UP,
			Vector2(x0, zc - C), Vector2(x1, zc - C), Vector2(x1, zc + C), Vector2(x0, zc + C), col, Vector2.ZERO, Color(0, 0, 0, 0),
			[Vector2(0, -C), Vector2(L, -C), Vector2(L, C), Vector2(0, C)])
		for side in [-1.0, 1.0]:
			var za: float = zc + side * C
			var zb: float = zc + side * H
			sw.quad(Vector3(x0, CH, za), Vector3(x1, CH, za), Vector3(x1, CH, zb), Vector3(x0, CH, zb), Vector3.UP,
				Vector2(x0, za), Vector2(x1, za), Vector2(x1, zb), Vector2(x0, zb), Color.WHITE, Vector2.ZERO, Color(0, 0, 0, 0),
				[Vector2(0, S), Vector2(0, S), Vector2(S, 0), Vector2(S, 0)])
			var nrm := Vector3(0, 0, -side)
			cb.quad(Vector3(x0, CH, za), Vector3(x1, CH, za), Vector3(x1, 0, za), Vector3(x0, 0, za), nrm,
				Vector2(x0, -CH), Vector2(x1, -CH), Vector2(x1, 0), Vector2(x0, 0))

# ---------------------------------------------------------------- junctions
const DIRV := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]

func _junctions() -> void:
	for j in range(0, D.n + 1):
		for i in range(0, D.n + 1):
			var arms: int = D.junction_arms(i, j)
			if arms == 0 or _straight(i, j):
				continue
			_emit_junction(i, j, arms)

func _w(cx: float, cz: float, p: Vector2, y: float) -> Vector3:
	return Vector3(cx + p.x, y, cz + p.y)

func _wuv(cx: float, cz: float, p: Vector2) -> Vector2:
	return Vector2(cx + p.x, cz + p.y)

func _emit_junction(i: int, j: int, arms: int) -> void:
	var c: Vector3 = Cfg.corner(i, j)
	var cx := c.x
	var cz := c.z
	junctions.append({"i": i, "j": j, "pos": c, "arms": arms})
	var ra := b("road")
	var sw := b("sidewalk")
	var cb := b("curb")
	var col := Color(1.0, float(arms) / 15.0, 0.0, 0.0)
	# core
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
			# sidewalk across the missing arm, curb face on the core edge facing the core
			var n3 := Vector3(-v.x, 0, -v.y)
			sw.quad(_w(cx, cz, p0, CH), _w(cx, cz, p1, CH), _w(cx, cz, p2, CH), _w(cx, cz, p3, CH), Vector3.UP,
				_wuv(cx, cz, p0), _wuv(cx, cz, p1), _wuv(cx, cz, p2), _wuv(cx, cz, p3), Color.WHITE, Vector2.ZERO, Color(0, 0, 0, 0),
				[Vector2(0, S), Vector2(0, S), Vector2(S, 0), Vector2(S, 0)])
			cb.quad(_w(cx, cz, p0, CH), _w(cx, cz, p1, CH), _w(cx, cz, p1, 0), _w(cx, cz, p0, 0), n3,
				Vector2(0, -CH), Vector2(2 * C, -CH), Vector2(2 * C, 0), Vector2(0, 0))
	# corner blocks k between arm k and arm k+1
	for k in 4:
		var vk: Vector2 = DIRV[k]
		var vk1: Vector2 = DIRV[(k + 1) % 4]
		var pk := (arms >> k) & 1 == 1
		var pk1 := (arms >> ((k + 1) % 4)) & 1 == 1
		var pc: Vector2 = vk * C + vk1 * C
		var pa: Vector2 = vk * H + vk1 * C     # outer edge point on arm-k side
		var pb: Vector2 = vk * C + vk1 * H
		var pk_far: Vector2 = vk * H + vk1 * H
		if pk and pk1:
			# fillet: asphalt fan from pc over the arc, sidewalk quarter disc around pk_far
			var arc: Array = []
			for s in FILLET_SEGS + 1:
				var phi := (PI * 0.5) * float(s) / float(FILLET_SEGS)
				arc.append(vk * (H - S * sin(phi)) + vk1 * (H - S * cos(phi)))
			for s in FILLET_SEGS:
				var q0: Vector2 = arc[s]
				var q1: Vector2 = arc[s + 1]
				ra.tri(_w(cx, cz, pc, 0), _w(cx, cz, q0, 0), _w(cx, cz, q1, 0), Vector3.UP,
					_wuv(cx, cz, pc), _wuv(cx, cz, q0), _wuv(cx, cz, q1), col, Vector2.ZERO, Color(0, 0, 0, 0),
					[pc, q0, q1])
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
				[Vector2(S, S), Vector2(S if pk else S, S), Vector2(S, S), Vector2(S, S)])
			if pk:
				# arm k asphalt borders the block along vk*r + vk1*C
				cb.quad(_w(cx, cz, pc, CH), _w(cx, cz, pa, CH), _w(cx, cz, pa, 0), _w(cx, cz, pc, 0), Vector3(-vk1.x, 0, -vk1.y),
					Vector2(0, -CH), Vector2(S, -CH), Vector2(S, 0), Vector2(0, 0))
			if pk1:
				cb.quad(_w(cx, cz, pc, CH), _w(cx, cz, pb, CH), _w(cx, cz, pb, 0), _w(cx, cz, pc, 0), Vector3(-vk.x, 0, -vk.y),
					Vector2(0, -CH), Vector2(S, -CH), Vector2(S, 0), Vector2(0, 0))

func _asph_quad(ra: RefCounted, cx: float, cz: float, p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, col: Color) -> void:
	ra.quad(_w(cx, cz, p0, 0), _w(cx, cz, p1, 0), _w(cx, cz, p2, 0), _w(cx, cz, p3, 0), Vector3.UP,
		_wuv(cx, cz, p0), _wuv(cx, cz, p1), _wuv(cx, cz, p2), _wuv(cx, cz, p3), col, Vector2.ZERO, Color(0, 0, 0, 0),
		[p0, p1, p2, p3])

# ---------------------------------------------------------------- lot pads
func _pad_key(t: Dictionary) -> String:
	var kind: String = t["kind"]
	match kind:
		"zoned":
			match int(t["zone"]):
				SC.Zone.R: return "grass"
				SC.Zone.C: return "paving"
				SC.Zone.I: return "gravel"
		"plant": return "gravel"
		"park": return "grass"
		"plaza": return "paving"
	return "grass"

func _pads() -> void:
	for tz in D.n:
		for tx in D.n:
			var t: Dictionary = D.tile(tx, tz)
			if t["owner"] == SC.Owner.NEUTRAL:
				continue
			var key := _pad_key(t)
			var bp := b(key)
			var o: Vector3 = Cfg.corner(tx, tz)
			var P := Cfg.P
			var roads: int = D.tile_roads(tx, tz)   # 1=N 2=E 4=S 8=W
			var pieces: Array = []
			pieces.append(Rect2(o.x + H, o.z + H, P - 2 * H, P - 2 * H))
			# sides without a road extend to the tile border (excluding corner squares)
			if roads & 1 == 0: pieces.append(Rect2(o.x + H, o.z, P - 2 * H, H))
			if roads & 4 == 0: pieces.append(Rect2(o.x + H, o.z + P - H, P - 2 * H, H))
			if roads & 8 == 0: pieces.append(Rect2(o.x, o.z + H, H, P - 2 * H))
			if roads & 2 == 0: pieces.append(Rect2(o.x + P - H, o.z + H, H, P - 2 * H))
			# corner squares that carry no junction
			if D.junction_arms(tx, tz) == 0: pieces.append(Rect2(o.x, o.z, H, H))
			if D.junction_arms(tx + 1, tz) == 0: pieces.append(Rect2(o.x + P - H, o.z, H, H))
			if D.junction_arms(tx, tz + 1) == 0: pieces.append(Rect2(o.x, o.z + P - H, H, H))
			if D.junction_arms(tx + 1, tz + 1) == 0: pieces.append(Rect2(o.x + P - H, o.z + P - H, H, H))
			for r in pieces:
				var rr: Rect2 = r
				bp.rect_xz(rr.position.x, rr.position.y, rr.end.x, rr.end.y, CH, true, 1.0, Color.WHITE, Vector2.ZERO, Vector2(0, 1.0))
				bp.box(Vector3(rr.position.x, -0.12, rr.position.y), Vector3(rr.end.x, CH, rr.end.y), Color.WHITE, 0x33, 1.0)

func _terrain() -> void:
	var r := 900.0
	var bt := b("terrain")
	bt.rect_xz(-r, -r, r, r, -0.06, true, 1.0)

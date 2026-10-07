extends RefCounted
## Street props: lamp posts (emissive head + light list for the limited OmniLight budget), traffic signals,
## street trees and lot trees (MultiMesh), parked cars (MultiMesh), benches, bins, hydrants, fences, fountains.

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")
const MB := preload("res://client/assets/techart/showcase_max/scripts/mesh_batch.gd")
const SC := preload("res://shared/slice_constants.gd")
const CarKit := preload("res://client/assets/techart/showcase_max/scripts/car_kit.gd")

const C := Cfg.C
const H := Cfg.H
const S := Cfg.S
const P := Cfg.P
const CH := Cfg.CURB_H

var D
var B: Dictionary
var runs: Array
var junctions: Array
var infos: Dictionary
var rng := RandomNumberGenerator.new()

var lamps: Array = []         # {head: Vector3, ground: Vector3, dir: Vector3}
var signals: Array = []
var tree_inst: Array = [[], [], []]       # per variant: Transform3D
var tree_col: Array = [[], [], []]
var bush_inst: Array = []
var bush_col: Array = []
var car_inst: Array = [[], [], [], []]
var car_col: Array = [[], [], [], []]

const CAR_PAINT := [Color(0.82, 0.83, 0.85), Color(0.7, 0.72, 0.75), Color(0.08, 0.08, 0.09), Color(0.2, 0.21, 0.23),
	Color(0.5, 0.08, 0.07), Color(0.1, 0.17, 0.32), Color(0.1, 0.25, 0.16), Color(0.72, 0.66, 0.54), Color(0.45, 0.58, 0.68),
	Color(0.85, 0.85, 0.83), Color(0.62, 0.2, 0.1)]
const LEAF := [Color(0.10, 0.24, 0.07), Color(0.14, 0.30, 0.08), Color(0.18, 0.32, 0.09), Color(0.12, 0.22, 0.06), Color(0.20, 0.30, 0.08)]

func _init(data, batches: Dictionary, road_runs: Array, road_junctions: Array, building_infos: Dictionary) -> void:
	D = data
	B = batches
	runs = road_runs
	junctions = road_junctions
	infos = building_infos
	rng.seed = 424242

func b(key: String) -> RefCounted:
	if not B.has(key):
		B[key] = MB.new()
	return B[key]

func build() -> void:
	_run_props()
	_junction_props()
	_lot_props()

# ----------------------------------------------------------------- helpers
## run-local (a along the axis, t right-hand lateral) -> world xz
static func run_pos(r: Dictionary, a: float, t: float) -> Vector3:
	var c0: Vector3 = r["c0"]
	if r["vertical"]:
		return Vector3(c0.x - t, 0.0, c0.z + H + a)
	return Vector3(c0.x + H + a, 0.0, c0.z + t)

static func run_dir(r: Dictionary) -> Vector3:
	return Vector3(0, 0, 1) if r["vertical"] else Vector3(1, 0, 0)

static func run_len(r: Dictionary) -> float:
	var c0: Vector3 = r["c0"]
	var c1: Vector3 = r["c1"]
	return (c1.z - c0.z - 2.0 * H) if r["vertical"] else (c1.x - c0.x - 2.0 * H)

static func yaw_of(dir: Vector3) -> float:
	return atan2(-dir.z, dir.x)

func _run_props() -> void:
	for r in runs:
		var L := run_len(r)
		var dirv := run_dir(r)
		var n_l := maxi(1, int(round(L / 24.0)))
		for k in n_l:
			var a := L * (float(k) + 0.5) / float(n_l)
			var side := 1.0 if ((k + int(r["line"]) + int(r["s0"])) % 2 == 0) else -1.0
			_lamp(run_pos(r, a, side * (C + 0.62)), -side, r)
		# street trees on both sidewalks
		var spacing := 11.0
		var n_t := maxi(1, int(round(L / spacing)))
		for side: float in [-1.0, 1.0]:
			for k in n_t:
				var a := L * (float(k) + 0.5) / float(n_t) + rng.randf_range(-1.0, 1.0)
				if absf(a - L * 0.5) < 2.2 and n_t == 1:
					a += 4.0
				if rng.randf() < 0.62:
					var p := run_pos(r, a, side * (C + S * 0.5 + 0.05))
					_tree(p, rng.randf_range(0.8, 1.05), rng.randi() % 3)
		# parked cars in the parking lanes
		var stall := 5.8
		var n_c := int(floor((L - 2.4) / stall))
		for side: float in [-1.0, 1.0]:
			for k in n_c:
				if rng.randf() < 0.6:
					continue
				var a := 1.2 + stall * (float(k) + 0.5) + rng.randf_range(-0.25, 0.25)
				var t := side * (C - Cfg.PARK_W * 0.5 + 0.1) + rng.randf_range(-0.08, 0.08)
				var p := run_pos(r, a, t)
				var facing := dirv * side * (1.0 if rng.randf() < 0.92 else -1.0)
				_car(p, facing)
		# benches / bins / hydrants on sidewalks
		for k in 1:
			if rng.randf() < 0.35:
				var a := rng.randf_range(3.0, maxf(3.5, L - 3.0))
				var side := 1.0 if rng.randf() < 0.5 else -1.0
				var p := run_pos(r, a, side * (C + S - 0.65))
				var face := -dirv.cross(Vector3.UP) * side if false else Vector3(0, 0, 0)
				_bench(p, run_dir(r), side)
		if rng.randf() < 0.3:
			var a2 := rng.randf_range(2.0, maxf(2.5, L - 2.0))
			var s2 := 1.0 if rng.randf() < 0.5 else -1.0
			_bin(run_pos(r, a2, s2 * (C + 0.5)))
		if rng.randf() < 0.22:
			var a3 := rng.randf_range(2.0, maxf(2.5, L - 2.0))
			var s3 := 1.0 if rng.randf() < 0.5 else -1.0
			_hydrant(run_pos(r, a3, s3 * (C + 0.4)))

func _lamp(ground: Vector3, toward_road: float, r: Dictionary) -> void:
	# pole on the sidewalk, arm reaching over the carriageway
	var lat_axis := Vector3(-1, 0, 0) if r["vertical"] else Vector3(0, 0, 1)   # direction of +t
	var arm_dir := lat_axis * toward_road
	var pole := b("lamp_pole")
	var h := 7.4
	pole.lathe(Vector3(ground.x, CH, ground.z), [Vector2(0.14, 0.0), Vector2(0.12, 0.6), Vector2(0.075, h)], 10, Color.WHITE, 1.0)
	pole.lathe(Vector3(ground.x, CH, ground.z), [Vector2(0.24, 0.0), Vector2(0.24, 0.35), Vector2(0.14, 0.45)], 10, Color.WHITE, 1.0)
	var top := Vector3(ground.x, CH + h, ground.z)
	var yaw := atan2(-arm_dir.z, arm_dir.x)
	var arm_len := 2.0
	var mid := top + arm_dir * (arm_len * 0.5) + Vector3(0, 0.15, 0)
	pole.box_yaw(mid, Vector3(arm_len, 0.1, 0.1), yaw, Color.WHITE, 0x37)
	var head_c := top + arm_dir * (arm_len - 0.1) + Vector3(0, 0.12, 0)
	pole.box_yaw(head_c + Vector3(0, 0.06, 0), Vector3(1.05, 0.12, 0.38), yaw, Color.WHITE, 0x37)
	var lamp := b("lamp")
	var yb := head_c.y - 0.01
	var dx := arm_dir
	var dz := arm_dir.cross(Vector3.UP).normalized()
	var p0 := head_c - dx * 0.48 - dz * 0.17
	var p1 := head_c + dx * 0.48 - dz * 0.17
	var p2 := head_c + dx * 0.48 + dz * 0.17
	var p3 := head_c - dx * 0.48 + dz * 0.17
	lamp.quad(Vector3(p0.x, yb, p0.z), Vector3(p1.x, yb, p1.z), Vector3(p2.x, yb, p2.z), Vector3(p3.x, yb, p3.z), Vector3.DOWN,
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), Color(1.0, 0.82, 0.55, 1.0))
	lamps.append({"head": Vector3(head_c.x, yb - 0.2, head_c.z), "ground": Vector3(head_c.x, 0.2, head_c.z)})
	# fake light pool
	var pl := b("pool")
	var pc := Vector3(head_c.x, 0.17, head_c.z)
	var rr := 7.5
	pl.quad(pc + Vector3(-rr, 0, -rr), pc + Vector3(rr, 0, -rr), pc + Vector3(rr, 0, rr), pc + Vector3(-rr, 0, rr), Vector3.UP,
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), Color(1.0, 0.72, 0.4, 1.0))

func _junction_props() -> void:
	for j in junctions:
		var arms: int = j["arms"]
		var cnt := (arms & 1) + ((arms >> 1) & 1) + ((arms >> 2) & 1) + ((arms >> 3) & 1)
		if cnt < 3:
			continue
		var pos: Vector3 = j["pos"]
		# signal poles at the four corner blocks
		for k in 4:
			var vk: Vector2 = [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)][k]
			var vk1: Vector2 = [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)][(k + 1) % 4]
			var pk := (arms >> k) & 1 == 1
			var pk1 := (arms >> ((k + 1) % 4)) & 1 == 1
			if not (pk and pk1):
				continue
			var q := vk * (C + 0.75) + vk1 * (C + 0.75)
			var ground := Vector3(pos.x + q.x, CH, pos.z + q.y)
			var green_ns: bool = ((int(j["i"]) + int(j["j"])) % 2 == 0)
			_signal(ground, Vector3(-vk.x - vk1.x, 0, -vk.y - vk1.y).normalized(), (k % 2 == 0) == green_ns)

func _signal(ground: Vector3, toward: Vector3, green: bool) -> void:
	var pole := b("lamp_pole")
	pole.lathe(ground, [Vector2(0.1, 0.0), Vector2(0.08, 4.2)], 8, Color.WHITE)
	var yaw := atan2(-toward.z, toward.x)
	# mast arm over the road
	var arm_c := ground + Vector3(0, 4.15, 0) + toward * 1.6
	pole.box_yaw(arm_c, Vector3(3.2, 0.08, 0.08), yaw, Color.WHITE, 0x37)
	# signal head on the arm
	var head := ground + Vector3(0, 3.6, 0) + toward * 2.9
	var hv := b("vcol")
	hv.box_yaw(head, Vector3(0.34, 1.1, 0.34), yaw, Color(0.04, 0.04, 0.05), 0x37)
	var em := b("lamp")
	var fwd := -toward
	var cols := [Color(1.0, 0.1, 0.05, 1.0), Color(1.0, 0.7, 0.0, 1.0), Color(0.1, 1.0, 0.3, 1.0)]
	for k in 3:
		var on := (k == 2 and green) or (k == 0 and not green)
		var cy := head.y + 0.34 - 0.34 * float(k)
		var c: Color = cols[k]
		c = c if on else c * 0.08
		c.a = 1.0 if on else 0.05
		var cc := head + fwd * 0.18
		var rr := 0.11
		var dx := fwd.cross(Vector3.UP).normalized() * rr
		em.quad(Vector3(cc.x - dx.x, cy + rr, cc.z - dx.z), Vector3(cc.x + dx.x, cy + rr, cc.z + dx.z), Vector3(cc.x + dx.x, cy - rr, cc.z + dx.z), Vector3(cc.x - dx.x, cy - rr, cc.z - dx.z), fwd,
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), c)

func _tree(p: Vector3, scale: float, variant: int) -> void:
	var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * scale), Vector3(p.x, CH, p.z))
	tree_inst[variant].append(xf)
	var c: Color = LEAF[rng.randi() % LEAF.size()]
	var k := rng.randf_range(0.85, 1.15)
	tree_col[variant].append(Color(c.r * k, c.g * k, c.b * k, 1.0))

func _bush(p: Vector3, scale: float) -> void:
	bush_inst.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * scale), Vector3(p.x, CH, p.z)))
	var c: Color = LEAF[rng.randi() % LEAF.size()]
	bush_col.append(Color(c.r * 0.9, c.g * 0.95, c.b * 0.9, 1.0))

func _car(p: Vector3, facing: Vector3) -> void:
	var r := rng.randf()
	var v := 0 if r < 0.42 else (1 if r < 0.68 else (2 if r < 0.92 else 3))
	car_inst[v].append(Transform3D(Basis(Vector3.UP, yaw_of(facing)), Vector3(p.x, 0.01, p.z)))
	car_col[v].append(CAR_PAINT[rng.randi() % CAR_PAINT.size()])

func _bench(p: Vector3, axis: Vector3, side: float) -> void:
	var yaw := atan2(-axis.z, axis.x)
	var wood := b("wood")
	var metal := b("metal_dark")
	wood.box_yaw(Vector3(p.x, CH + 0.46, p.z), Vector3(1.7, 0.05, 0.22), yaw, Color.WHITE, 0x37)
	var off := axis.cross(Vector3.UP).normalized() * side * 0.17
	wood.box_yaw(Vector3(p.x, CH + 0.46, p.z) + off, Vector3(1.7, 0.05, 0.22), yaw, Color.WHITE, 0x37)
	wood.box_yaw(Vector3(p.x, CH + 0.78, p.z) + off * 2.2, Vector3(1.7, 0.2, 0.04), yaw, Color.WHITE, 0x37)
	for sx: float in [-0.75, 0.75]:
		var lp := Vector3(p.x, CH + 0.23, p.z) + axis * sx
		metal.box_yaw(lp, Vector3(0.05, 0.46, 0.45), yaw, Color.WHITE, 0x37)

func _bin(p: Vector3) -> void:
	b("vcol").lathe(Vector3(p.x, CH, p.z), [Vector2(0.28, 0.0), Vector2(0.3, 0.8), Vector2(0.0, 0.8)], 10, Color(0.1, 0.22, 0.14))
	b("vcol").lathe(Vector3(p.x, CH + 0.8, p.z), [Vector2(0.32, 0.0), Vector2(0.32, 0.06), Vector2(0.0, 0.1)], 10, Color(0.06, 0.07, 0.07))

func _hydrant(p: Vector3) -> void:
	var v := b("vcol")
	v.lathe(Vector3(p.x, CH, p.z), [Vector2(0.14, 0.0), Vector2(0.12, 0.5), Vector2(0.13, 0.62), Vector2(0.0, 0.7)], 10, Color(0.75, 0.1, 0.07))
	v.box_yaw(Vector3(p.x, CH + 0.45, p.z), Vector3(0.38, 0.1, 0.1), 0.0, Color(0.75, 0.1, 0.07), 0x37)

# ----------------------------------------------------------------- lots
func _lot_props() -> void:
	for t in D.tiles:
		var o: Vector3 = Cfg.corner(t["x"], t["z"])
		var x0 := o.x + H
		var z0 := o.z + H
		var x1 := o.x + P - H
		var z1 := o.z + P - H
		var rng_t := RandomNumberGenerator.new()
		rng_t.seed = int(t["seed"]) + 99
		if t["owner"] == SC.Owner.NEUTRAL:
			_neutral_tile(o, rng_t)
			continue
		var kind: String = t["kind"]
		var rect := _building_rect(t)
		match kind:
			"park":
				_park(o, x0, z0, x1, z1, rng_t)
			"plaza":
				_plaza(o, x0, z0, x1, z1, rng_t)
			"plant":
				_fence(x0 + 0.3, z0 + 0.3, x1 - 0.3, z1 - 0.3, 0)
			"zoned":
				if not t["has_building"]:
					_vacant(x0, z0, x1, z1, rng_t)
				else:
					match int(t["zone"]):
						SC.Zone.R:
							var n := rng_t.randi_range(2, 4)
							_lot_trees(x0, z0, x1, z1, rect, n, rng_t)
							_hedge_front(t, x0, z0, x1, z1, rect)
						SC.Zone.C:
							_lot_trees(x0, z0, x1, z1, rect, rng_t.randi_range(1, 3), rng_t)
							_planters(x0, z0, x1, z1, rect, rng_t)
						SC.Zone.I:
							_fence(x0 + 0.2, z0 + 0.2, x1 - 0.2, z1 - 0.2, int(t["front"]))
							_containers(x0, z0, x1, z1, rect, rng_t)

func _building_rect(t: Dictionary) -> Rect2:
	if not infos.has(t["id"]):
		return Rect2(Vector2(-1e5, -1e5), Vector2.ZERO)
	var inf: Dictionary = infos[t["id"]]
	var c3: Vector3 = inf["center"]
	var sz: Vector2 = inf["size"]
	var f: int = inf["f"]
	var ex := sz.x if (f == 0 or f == 2) else sz.y
	var ez := sz.y if (f == 0 or f == 2) else sz.x
	return Rect2(c3.x - ex * 0.5, c3.z - ez * 0.5, ex, ez)

func _lot_trees(x0: float, z0: float, x1: float, z1: float, rect: Rect2, n: int, r: RandomNumberGenerator) -> void:
	var placed := 0
	var tries := 0
	while placed < n and tries < 60:
		tries += 1
		var p := Vector2(r.randf_range(x0 + 1.4, x1 - 1.4), r.randf_range(z0 + 1.4, z1 - 1.4))
		if rect.grow(2.2).has_point(p):
			continue
		_tree(Vector3(p.x, 0, p.y), r.randf_range(0.7, 0.95), r.randi() % 3)
		placed += 1

func _hedge_front(t: Dictionary, x0: float, z0: float, x1: float, z1: float, rect: Rect2) -> void:
	# low hedge along the lot edge facing the road (if any)
	var roads: int = D.tile_roads(t["x"], t["z"])
	var hb := b("hedge")
	var h := 0.75
	var w := 0.7
	var gap := 2.4
	if roads & 1:
		_hedge_line(hb, x0 + 0.3, z0 + 0.45, x1 - 0.3, z0 + 0.45, h, w, 0)
	if roads & 4:
		_hedge_line(hb, x0 + 0.3, z1 - 0.45, x1 - 0.3, z1 - 0.45, h, w, 0)
	if roads & 8:
		_hedge_line(hb, x0 + 0.45, z0 + 0.3, x0 + 0.45, z1 - 0.3, h, w, 0)
	if roads & 2:
		_hedge_line(hb, x1 - 0.45, z0 + 0.3, x1 - 0.45, z1 - 0.3, h, w, 0)

func _hedge_line(hb: RefCounted, ax: float, az: float, bx: float, bz: float, h: float, w: float, _k: int) -> void:
	var len := Vector2(bx - ax, bz - az).length()
	var n := maxi(1, int(len / 1.6))
	var dir := Vector2(bx - ax, bz - az).normalized()
	var yaw := atan2(-dir.y, dir.x)
	for i in n:
		var u := (float(i) + 0.5) / float(n)
		var pp := Vector2(ax, az).lerp(Vector2(bx, bz), u)
		hb.box_yaw(Vector3(pp.x, CH + h * 0.5, pp.y), Vector3(len / float(n) + 0.05, h * (0.92 + 0.16 * sin(float(i) * 2.3)), w), yaw, Color(0.14 + 0.05 * sin(float(i)), 0.3, 0.1), 0x37)

func _planters(x0: float, z0: float, x1: float, z1: float, rect: Rect2, r: RandomNumberGenerator) -> void:
	for k in 3:
		var p := Vector2(r.randf_range(x0 + 1.0, x1 - 1.0), r.randf_range(z0 + 1.0, z1 - 1.0))
		if rect.grow(1.2).has_point(p):
			continue
		b("concrete").box_yaw(Vector3(p.x, CH + 0.3, p.y), Vector3(1.4, 0.6, 1.4), 0.0, Color.WHITE, 0x37)
		_bush(Vector3(p.x, 0.5, p.y), 0.9)

func _park(o: Vector3, x0: float, z0: float, x1: float, z1: float, r: RandomNumberGenerator) -> void:
	var n := r.randi_range(7, 12)
	for k in n:
		var p := Vector2(r.randf_range(x0 + 1.5, x1 - 1.5), r.randf_range(z0 + 1.5, z1 - 1.5))
		if absf(p.x - (x0 + x1) * 0.5) < 1.6 or absf(p.y - (z0 + z1) * 0.5) < 1.6:
			continue
		_tree(Vector3(p.x, 0, p.y), r.randf_range(0.8, 1.2), r.randi() % 3)
	# crossing paths
	var path := b("path")
	var cx := (x0 + x1) * 0.5
	var cz := (z0 + z1) * 0.5
	path.rect_xz(x0, cz - 0.9, x1, cz + 0.9, CH + 0.02, true, 1.0)
	path.rect_xz(cx - 0.9, z0, cx + 0.9, z1, CH + 0.02, true, 1.0)
	_bench(Vector3(cx + 2.2, 0, cz - 1.6), Vector3(1, 0, 0), -1.0)
	_bench(Vector3(cx - 2.2, 0, cz + 1.6), Vector3(1, 0, 0), 1.0)
	_bush(Vector3(cx + 3.5, 0, cz + 3.5), 1.3)
	_bush(Vector3(cx - 3.8, 0, cz - 3.2), 1.1)

func _plaza(o: Vector3, x0: float, z0: float, x1: float, z1: float, r: RandomNumberGenerator) -> void:
	var cx := (x0 + x1) * 0.5
	var cz := (z0 + z1) * 0.5
	# fountain basin
	b("concrete").lathe(Vector3(cx, CH, cz), [Vector2(3.0, 0.0), Vector2(3.0, 0.55), Vector2(2.7, 0.55)], 28)
	b("water").lathe(Vector3(cx, CH + 0.4, cz), [Vector2(0.0, 0.0), Vector2(2.7, 0.0)], 28)
	b("concrete").lathe(Vector3(cx, CH, cz), [Vector2(0.5, 0.0), Vector2(0.4, 1.0), Vector2(0.9, 1.1), Vector2(0.9, 1.25), Vector2(0.0, 1.25)], 16)
	for k in 4:
		var a := PI * 0.25 + PI * 0.5 * float(k)
		var p := Vector2(cx + cos(a) * 5.6, cz + sin(a) * 5.6)
		_tree(Vector3(p.x, 0, p.y), r.randf_range(0.7, 0.9), 2)
		b("concrete").box_yaw(Vector3(p.x, CH + 0.25, p.y), Vector3(1.3, 0.5, 1.3), 0.0, Color.WHITE, 0x37)
		_bench(Vector3(cx + cos(a + 0.5) * 5.0, 0, cz + sin(a + 0.5) * 5.0), Vector3(-sin(a + 0.5), 0, cos(a + 0.5)), 1.0)

func _vacant(x0: float, z0: float, x1: float, z1: float, r: RandomNumberGenerator) -> void:
	_fence(x0 + 0.5, z0 + 0.5, x1 - 0.5, z1 - 0.5, 0)
	# zoning sign
	b("metal_dark").box_yaw(Vector3((x0 + x1) * 0.5, CH + 1.3, z1 - 0.8), Vector3(2.2, 1.3, 0.08), 0.0, Color.WHITE, 0x37)
	for k in 5:
		var p := Vector2(r.randf_range(x0 + 2.0, x1 - 2.0), r.randf_range(z0 + 2.0, z1 - 3.0))
		b("concrete").box_yaw(Vector3(p.x, CH + 0.35, p.y), Vector3(r.randf_range(1.0, 2.0), 0.7, r.randf_range(1.0, 2.0)), r.randf() * TAU, Color.WHITE, 0x37)

func _fence(x0: float, z0: float, x1: float, z1: float, _gate_side: int) -> void:
	var post := b("metal_dark")
	var h := 2.0
	var segs := [[x0, z0, x1, z0], [x1, z0, x1, z1], [x1, z1, x0, z1], [x0, z1, x0, z0]]
	for s in segs:
		var a := Vector2(s[0], s[1])
		var e := Vector2(s[2], s[3])
		var len := a.distance_to(e)
		var n := maxi(1, int(len / 3.0))
		var dir := (e - a).normalized()
		var yaw := atan2(-dir.y, dir.x)
		for i in n + 1:
			var p := a.lerp(e, float(i) / float(n))
			post.box_yaw(Vector3(p.x, CH + h * 0.5, p.y), Vector3(0.07, h, 0.07), 0.0, Color.WHITE, 0x37)
		var mid := (a + e) * 0.5
		for hh: float in [0.25, 1.0, 1.95]:
			post.box_yaw(Vector3(mid.x, CH + hh, mid.y), Vector3(len, 0.04, 0.04), yaw, Color.WHITE, 0x37)
		# mesh panel
		b("fence_mesh").box_yaw(Vector3(mid.x, CH + 1.0, mid.y), Vector3(len, 1.8, 0.02), yaw, Color.WHITE, 0x37)

func _containers(x0: float, z0: float, x1: float, z1: float, rect: Rect2, r: RandomNumberGenerator) -> void:
	var pal := [Color(0.62, 0.17, 0.1), Color(0.15, 0.3, 0.5), Color(0.8, 0.55, 0.12), Color(0.2, 0.4, 0.28), Color(0.55, 0.55, 0.55)]
	for k in 3:
		var p := Vector2(r.randf_range(x0 + 2.0, x1 - 2.0), r.randf_range(z0 + 2.0, z1 - 2.0))
		if rect.grow(1.5).has_point(p):
			continue
		var yaw := 0.0 if r.randf() < 0.5 else PI * 0.5
		var col: Color = pal[r.randi() % pal.size()]
		var stack := r.randi_range(1, 2)
		for s in stack:
			b("container").box_yaw(Vector3(p.x, CH + 1.3 + 2.6 * float(s), p.y), Vector3(6.0, 2.6, 2.4), yaw, col, 0x37)

func _neutral_tile(o: Vector3, r: RandomNumberGenerator) -> void:
	var n := r.randi_range(2, 7)
	var c := Vector2(o.x + r.randf_range(8.0, P - 8.0), o.z + r.randf_range(8.0, P - 8.0))
	for k in n:
		var p := c + Vector2(r.randfn(0.0, 4.5), r.randfn(0.0, 4.5))
		if p.x < o.x + 1.0 or p.x > o.x + P - 1.0 or p.y < o.z + 1.0 or p.y > o.z + P - 1.0:
			continue
		_tree_land(Vector3(p.x, 0, p.y), r.randf_range(0.8, 1.3), r.randi() % 3)
	for k in r.randi_range(0, 3):
		var p2 := Vector2(o.x + r.randf_range(3.0, P - 3.0), o.z + r.randf_range(3.0, P - 3.0))
		_bush_land(Vector3(p2.x, 0, p2.y), r.randf_range(0.8, 1.6))

func _tree_land(p: Vector3, scale: float, variant: int) -> void:
	var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * scale), Vector3(p.x, -0.06, p.z))
	tree_inst[variant].append(xf)
	var c: Color = LEAF[rng.randi() % LEAF.size()]
	var k := rng.randf_range(0.8, 1.15)
	tree_col[variant].append(Color(c.r * k, c.g * k, c.b * k, 1.0))

func _bush_land(p: Vector3, scale: float) -> void:
	bush_inst.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * scale), Vector3(p.x, -0.06, p.z)))
	var c: Color = LEAF[rng.randi() % LEAF.size()]
	bush_col.append(Color(c.r * 0.85, c.g * 0.9, c.b * 0.8, 1.0))

# ----------------------------------------------------------------- tree meshes (MultiMesh)
static func _blob(m: RefCounted, c: Vector3, rad: Vector3, rings: int, segs: int, seed: float, col_dark: Color, col_light: Color) -> void:
	var base: int = m.verts.size()
	for i in rings + 1:
		var th := PI * float(i) / float(rings)
		for j in segs + 1:
			var ph := TAU * float(j) / float(segs)
			var dir := Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
			var n1 := sin(dir.x * 3.1 + seed) * sin(dir.y * 2.7 + seed * 1.7) * sin(dir.z * 3.3 + seed * 0.6)
			var disp := 1.0 + 0.16 * n1 + 0.06 * sin(ph * 5.0 + seed * 3.0) * sin(th * 4.0)
			var p := c + Vector3(dir.x * rad.x, dir.y * rad.y, dir.z * rad.z) * disp
			m.verts.append(p)
			var nrm := (dir + Vector3(0, 0.25, 0)).normalized()
			m.norms.append(nrm)
			m.uvs.append(Vector2(float(j) / float(segs), float(i) / float(rings)))
			m.uv2s.append(Vector2.ZERO)
			var f := clampf(dir.y * 0.5 + 0.5, 0.0, 1.0)
			f = f * f
			m.cols.append(col_dark.lerp(col_light, f))
			m.tans.append(1.0)
			m.tans.append(0.0)
			m.tans.append(0.0)
			m.tans.append(1.0)
	for i in rings:
		for j in segs:
			var a0 := base + i * (segs + 1) + j
			var a1 := a0 + 1
			var b0 := a0 + segs + 1
			var b1 := b0 + 1
			var tn: Vector3 = (m.verts[b0] - m.verts[a0]).cross(m.verts[a1] - m.verts[a0])
			if tn.dot(m.norms[a0]) > 0.0:
				m.idx.append_array([a0, a1, b0, a1, b1, b0])
			else:
				m.idx.append_array([a0, b0, a1, a1, b0, b1])

static func make_tree_meshes() -> Array:
	# returns [trunk_mesh_with_canopy: ArrayMesh with surface 0 trunk (bark) + surface 1 foliage] per variant (3) + bush
	var out: Array = []
	var specs := [
		{"trunk_h": 3.4, "blobs": [[0, 4.6, 0, 2.2, 1.8], [1.3, 5.4, 0.4, 1.6, 1.4], [-1.2, 5.6, -0.6, 1.7, 1.4], [0.3, 6.6, 0.0, 1.5, 1.3], [0.4, 5.0, -1.4, 1.5, 1.2], [-0.6, 4.8, 1.3, 1.5, 1.2]]},
		{"trunk_h": 2.6, "blobs": [[0, 5.2, 0, 1.4, 2.6], [0.5, 6.8, 0.2, 1.1, 1.8], [-0.4, 4.0, 0.3, 1.2, 1.5]]},
		{"trunk_h": 2.4, "blobs": [[0, 3.8, 0, 1.7, 1.5], [0.9, 4.3, 0.3, 1.2, 1.1], [-0.8, 4.4, -0.4, 1.2, 1.1], [0.1, 5.0, 0.1, 1.1, 1.0]]},
	]
	var sd := 3.0
	for spec in specs:
		var trunk = MB.new()
		var foliage = MB.new()
		var th: float = spec["trunk_h"]
		trunk.lathe(Vector3.ZERO, [Vector2(0.30, 0.0), Vector2(0.22, 0.6), Vector2(0.17, th), Vector2(0.12, th + 1.4)], 10, Color(0.24, 0.17, 0.12))
		# a couple of branches
		for k in 3:
			var ang := float(k) * 2.1 + sd
			var dirb := Vector3(cos(ang), 0.7, sin(ang)).normalized()
			trunk.box_yaw(Vector3(0, th + 0.8, 0) + dirb * 0.9, Vector3(0.1, 1.9, 0.1), ang, Color(0.22, 0.16, 0.11), 0x37)
		for bl in spec["blobs"]:
			_blob(foliage, Vector3(bl[0], bl[1], bl[2]), Vector3(bl[3], bl[4], bl[3]), 7, 12, sd, Color(0.38, 0.4, 0.35), Color(1.0, 1.0, 0.95))
			sd += 1.7
		var mesh := ArrayMesh.new()
		trunk.commit(mesh)
		foliage.commit(mesh)
		out.append(mesh)
	# bush
	var bf = MB.new()
	_blob(bf, Vector3(0, 0.55, 0), Vector3(0.9, 0.7, 0.9), 6, 10, 9.0, Color(0.35, 0.38, 0.32), Color(1.0, 1.0, 0.95))
	_blob(bf, Vector3(0.5, 0.45, 0.3), Vector3(0.6, 0.5, 0.6), 5, 8, 11.0, Color(0.35, 0.38, 0.32), Color(1.0, 1.0, 0.95))
	var bm := ArrayMesh.new()
	bf.commit(bm)
	out.append(bm)
	return out

## Create MultiMesh instance nodes for trees, bushes and cars.
func make_instance_nodes(parent: Node3D, mats) -> Array:
	var nodes: Array = []
	var tmeshes := make_tree_meshes()
	for v in 3:
		if tree_inst[v].is_empty():
			continue
		nodes.append(_mm(parent, tmeshes[v], tree_inst[v], tree_col[v], [mats.m["bark"], mats.m["foliage"]], "trees_%d" % v, true))
	if not bush_inst.is_empty():
		nodes.append(_mm(parent, tmeshes[3], bush_inst, bush_col, [mats.m["foliage"]], "bushes", true))
	for v in 4:
		if car_inst[v].is_empty():
			continue
		var m := CarKit.make(v)
		nodes.append(_mm(parent, m, car_inst[v], car_col[v], [mats.m["car_paint"], mats.m["car_glass"], mats.m["car_trim"], mats.m["car_lights"]], "cars_%d" % v, true))
	return nodes

func _mm(parent: Node3D, mesh: ArrayMesh, xfs: Array, cols: Array, surf_mats: Array, name: String, shadow: bool) -> MultiMeshInstance3D:
	for i in surf_mats.size():
		mesh.surface_set_material(i, surf_mats[i])
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
		mm.set_instance_color(i, cols[i])
	var mi := MultiMeshInstance3D.new()
	mi.name = name
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

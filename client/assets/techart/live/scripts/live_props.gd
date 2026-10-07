extends RefCounted
## Street and lot props for one block, adapted from showcase prop_builder.gd: lamp posts along
## road runs, street trees, parked cars, lot trees, hedges, planters, fences and containers.
## Trees, bushes and cars are MultiMesh instances (transform + colour lists per variant); the
## rest is batched geometry. Lot props are produced per tile by lot() so BlockView caches them
## with the tile's building; street props (lamps, street trees, cars) follow the road runs and
## are rebuilt with the ground layer. Lighter than the showcase: wider lamp and tree spacing,
## fewer cars, no benches / bins / hydrants / fountains / fence mesh panels / lamp pools.

const Cfg := preload("res://client/assets/techart/live/scripts/live_cfg.gd")
const LB := preload("res://client/assets/techart/live/scripts/live_batch.gd")
const Mats := preload("res://client/assets/techart/live/scripts/live_mats.gd")
const SC := preload("res://shared/slice_constants.gd")
const MB := preload("res://client/assets/techart/showcase_max/scripts/mesh_batch.gd")
const ShowcaseProps := preload("res://client/assets/techart/showcase_max/scripts/prop_builder.gd")
const CarKit := preload("res://client/assets/techart/showcase_max/scripts/car_kit.gd")

const C := Cfg.C
const H := Cfg.H
const S := Cfg.S
const P := Cfg.P
const CH := Cfg.CURB_H

const TREE_VARIANTS := 3
## Car kit variants used (sedan, suv).
const CAR_KITS := [0, 2]
const CAR_PAINT := ShowcaseProps.CAR_PAINT
const LEAF := ShowcaseProps.LEAF

var rng := RandomNumberGenerator.new()

## Street output (build_street): batches plus instance lists.
var B: Dictionary = {}
var tree_inst: Array = [[], [], []]
var tree_col: Array = [[], [], []]
var car_inst: Array = [[], []]
var car_col: Array = [[], []]
var lamp_count := 0


func b(key: String) -> RefCounted:
	if not B.has(key):
		B[key] = LB.new()
	return B[key]


## Empty instance-list container in the shape lot() returns and BlockView merges.
static func empty_instances() -> Dictionary:
	return {"trees": [[], [], []], "tree_cols": [[], [], []], "bushes": [], "bush_cols": []}


# ----------------------------------------------------------------- street (per block)
## run-local (a along the axis from a0, t right-hand lateral) -> world xz
static func run_pos(r: Dictionary, a: float, t: float) -> Vector3:
	if r["vertical"]:
		return Vector3(r["cross"] - t, 0.0, r["a0"] + a)
	return Vector3(r["a0"] + a, 0.0, r["cross"] + t)


static func run_dir(r: Dictionary) -> Vector3:
	return Vector3(0, 0, 1) if r["vertical"] else Vector3(1, 0, 0)


static func yaw_of(dir: Vector3) -> float:
	return atan2(-dir.z, dir.x)


## Lamps, street trees and parked cars along the block's road runs (live_roads.gd runs).
## `cache` (owned by BlockView) keeps one entry per run key so unchanged runs are merged, not
## regenerated; runs that disappeared are dropped from it.
func build_street(runs: Array, batches: Dictionary, cache: Dictionary = {}) -> void:
	B = batches
	var kept := {}
	for r in runs:
		var rkey := "%s/%d/%.2f/%.2f" % ["v" if r["vertical"] else "h", int(r["line"]), float(r["a0"]), float(r["a1"])]
		var entry = cache.get(rkey)
		if entry == null:
			entry = _run_props(r)
		kept[rkey] = entry
		var eb: Dictionary = entry["batches"]
		for k in eb:
			b(k).append(eb[k])
		for v in TREE_VARIANTS:
			tree_inst[v].append_array(entry["trees"][v])
			tree_col[v].append_array(entry["tree_cols"][v])
		for v in CAR_KITS.size():
			car_inst[v].append_array(entry["cars"][v])
			car_col[v].append_array(entry["car_cols"][v])
		lamp_count += int(entry["lamps"])
	cache.clear()
	cache.merge(kept)


## Props of one run: {batches, trees, tree_cols, cars, car_cols, lamps}. Deterministic per run.
func _run_props(r: Dictionary) -> Dictionary:
	var saved_b := B
	var saved_lamps := lamp_count
	B = {}
	lamp_count = 0
	var trees: Array = [[], [], []]
	var tree_cols: Array = [[], [], []]
	var cars: Array = [[], []]
	var car_cols: Array = [[], []]
	rng.seed = int(r["line"]) * 7919 + int(r["s0"]) * 131 + (1 if r["vertical"] else 0)
	var L: float = r["a1"] - r["a0"]
	var dirv := run_dir(r)
	var n_l := maxi(1, int(round(L / 30.0)))
	for k in n_l:
		var a := L * (float(k) + 0.5) / float(n_l)
		var side := 1.0 if ((k + int(r["line"]) + int(r["s0"])) % 2 == 0) else -1.0
		_lamp(run_pos(r, a, side * (C + 0.62)), -side, r)
	var spacing := 14.0
	var n_t := maxi(1, int(round(L / spacing)))
	for side: float in [-1.0, 1.0]:
		for k in n_t:
			var a := L * (float(k) + 0.5) / float(n_t) + rng.randf_range(-1.0, 1.0)
			if rng.randf() < 0.55:
				var p := run_pos(r, a, side * (C + S * 0.5 + 0.05))
				var v := rng.randi() % TREE_VARIANTS
				trees[v].append(_tree_xf(p, rng.randf_range(0.8, 1.05), CH))
				tree_cols[v].append(_leaf_col(1.0))
	var stall := 5.8
	var n_c := int(floor((L - 2.4) / stall))
	for side: float in [-1.0, 1.0]:
		for k in n_c:
			if rng.randf() < 0.7:
				continue
			var a := 1.2 + stall * (float(k) + 0.5) + rng.randf_range(-0.25, 0.25)
			var t := side * (C - Cfg.PARK_W * 0.5 + 0.1) + rng.randf_range(-0.08, 0.08)
			var p := run_pos(r, a, t)
			var facing := dirv * side * (1.0 if rng.randf() < 0.92 else -1.0)
			var v := 0 if rng.randf() < 0.65 else 1
			cars[v].append(Transform3D(Basis(Vector3.UP, yaw_of(facing)), Vector3(p.x, 0.01, p.z)))
			car_cols[v].append(CAR_PAINT[rng.randi() % CAR_PAINT.size()])
	var entry := {"batches": B, "trees": trees, "tree_cols": tree_cols, "cars": cars, "car_cols": car_cols, "lamps": lamp_count}
	B = saved_b
	lamp_count = saved_lamps
	return entry


func _lamp(ground: Vector3, toward_road: float, r: Dictionary) -> void:
	var lat_axis := Vector3(-1, 0, 0) if r["vertical"] else Vector3(0, 0, 1)
	var arm_dir := lat_axis * toward_road
	var pole := b("prop")
	var h := 7.4
	pole.lathe(Vector3(ground.x, CH, ground.z), [Vector2(0.14, 0.0), Vector2(0.12, 0.6), Vector2(0.075, h)], 8, Mats.COL_POLE, 1.0)
	var top := Vector3(ground.x, CH + h, ground.z)
	var yaw := atan2(-arm_dir.z, arm_dir.x)
	var arm_len := 2.0
	var mid := top + arm_dir * (arm_len * 0.5) + Vector3(0, 0.15, 0)
	pole.box_yaw(mid, Vector3(arm_len, 0.1, 0.1), yaw, Mats.COL_POLE, 0x37)
	var head_c := top + arm_dir * (arm_len - 0.1) + Vector3(0, 0.12, 0)
	pole.box_yaw(head_c + Vector3(0, 0.06, 0), Vector3(1.05, 0.12, 0.38), yaw, Mats.COL_POLE, 0x37)
	var lamp := b("emit")
	var yb := head_c.y - 0.01
	var dx := arm_dir
	var dz := arm_dir.cross(Vector3.UP).normalized()
	var p0 := head_c - dx * 0.48 - dz * 0.17
	var p1 := head_c + dx * 0.48 - dz * 0.17
	var p2 := head_c + dx * 0.48 + dz * 0.17
	var p3 := head_c - dx * 0.48 + dz * 0.17
	lamp.quad(Vector3(p0.x, yb, p0.z), Vector3(p1.x, yb, p1.z), Vector3(p2.x, yb, p2.z), Vector3(p3.x, yb, p3.z), Vector3.DOWN,
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), Color(1.0, 0.82, 0.55, 1.0))
	lamp_count += 1


func _tree_xf(p: Vector3, scale: float, y: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * scale), Vector3(p.x, y, p.z))


func _leaf_col(mul: float) -> Color:
	var c: Color = LEAF[rng.randi() % LEAF.size()]
	var k := rng.randf_range(0.85, 1.15) * mul
	return Color(c.r * k, c.g * k, c.b * k, 1.0)


# ----------------------------------------------------------------- lots (per tile)
## Lot props of one tile into `batches` (prop / vcol / concrete keys); returns the tree and bush
## instance lists (empty_instances() shape). Deterministic per tile id.
func lot(t: TileDelta, roads: int, info: Dictionary, batches: Dictionary) -> Dictionary:
	B = batches
	var inst := empty_instances()
	rng.seed = int(Cfg.hash01(t.id, 99) * 2147483000.0)
	var o := Cfg.corner(t.x, t.y)
	var x0 := o.x + H
	var z0 := o.z + H
	var x1 := o.x + P - H
	var z1 := o.z + P - H
	if t.owner == SC.Owner.NEUTRAL:
		_neutral_tile(o, inst)
		return inst
	var rect := _building_rect(info)
	if t.zone == SC.Zone.NONE:
		if rng.randf() < 0.5:
			_lot_trees(x0, z0, x1, z1, rect, 1, inst)
		return inst
	if not t.has_building or info.is_empty():
		_vacant(x0, z0, x1, z1)
		return inst
	match t.zone:
		SC.Zone.R:
			_lot_trees(x0, z0, x1, z1, rect, rng.randi_range(1, 2), inst)
			_hedge_front(roads, x0, z0, x1, z1)
		SC.Zone.C:
			_lot_trees(x0, z0, x1, z1, rect, rng.randi_range(1, 2), inst)
			_planters(x0, z0, x1, z1, rect, inst)
		SC.Zone.I:
			_fence(x0 + 0.2, z0 + 0.2, x1 - 0.2, z1 - 0.2)
			_containers(x0, z0, x1, z1, rect)
	return inst


static func _building_rect(info: Dictionary) -> Rect2:
	if info.is_empty():
		return Rect2(Vector2(-1e5, -1e5), Vector2.ZERO)
	var c3: Vector3 = info["center"]
	var sz: Vector2 = info["size"]
	var f: int = info["f"]
	var ex := sz.x if (f == 0 or f == 2) else sz.y
	var ez := sz.y if (f == 0 or f == 2) else sz.x
	return Rect2(c3.x - ex * 0.5, c3.z - ez * 0.5, ex, ez)


func _lot_trees(x0: float, z0: float, x1: float, z1: float, rect: Rect2, n: int, inst: Dictionary) -> void:
	var placed := 0
	var tries := 0
	while placed < n and tries < 30:
		tries += 1
		var p := Vector2(rng.randf_range(x0 + 1.4, x1 - 1.4), rng.randf_range(z0 + 1.4, z1 - 1.4))
		if rect.grow(2.2).has_point(p):
			continue
		var v := rng.randi() % TREE_VARIANTS
		inst["trees"][v].append(_tree_xf(Vector3(p.x, 0, p.y), rng.randf_range(0.7, 0.95), CH))
		inst["tree_cols"][v].append(_leaf_col(1.0))
		placed += 1


func _hedge_front(roads: int, x0: float, z0: float, x1: float, z1: float) -> void:
	var hb := b("vcol")
	var h := 0.75
	var w := 0.7
	if roads & 1:
		_hedge_line(hb, x0 + 0.3, z0 + 0.45, x1 - 0.3, z0 + 0.45, h, w)
	if roads & 4:
		_hedge_line(hb, x0 + 0.3, z1 - 0.45, x1 - 0.3, z1 - 0.45, h, w)
	if roads & 8:
		_hedge_line(hb, x0 + 0.45, z0 + 0.3, x0 + 0.45, z1 - 0.3, h, w)
	if roads & 2:
		_hedge_line(hb, x1 - 0.45, z0 + 0.3, x1 - 0.45, z1 - 0.3, h, w)


func _hedge_line(hb: RefCounted, ax: float, az: float, bx: float, bz: float, h: float, w: float) -> void:
	var len := Vector2(bx - ax, bz - az).length()
	var n := maxi(1, int(len / 2.4))
	var dir := Vector2(bx - ax, bz - az).normalized()
	var yaw := atan2(-dir.y, dir.x)
	for i in n:
		var u := (float(i) + 0.5) / float(n)
		var pp := Vector2(ax, az).lerp(Vector2(bx, bz), u)
		hb.box_yaw(Vector3(pp.x, CH + h * 0.5, pp.y), Vector3(len / float(n) + 0.05, h * (0.92 + 0.16 * sin(float(i) * 2.3)), w), yaw, Color(0.14 + 0.05 * sin(float(i)), 0.3, 0.1), 0x37)


func _planters(x0: float, z0: float, x1: float, z1: float, rect: Rect2, inst: Dictionary) -> void:
	for k in 2:
		var p := Vector2(rng.randf_range(x0 + 1.0, x1 - 1.0), rng.randf_range(z0 + 1.0, z1 - 1.0))
		if rect.grow(1.2).has_point(p):
			continue
		b("concrete").box_yaw(Vector3(p.x, CH + 0.3, p.y), Vector3(1.4, 0.6, 1.4), 0.0, Color.WHITE, 0x37)
		inst["bushes"].append(_tree_xf(Vector3(p.x, 0, p.y), 0.9, CH + 0.5))
		inst["bush_cols"].append(_leaf_col(0.92))


func _vacant(x0: float, z0: float, x1: float, z1: float) -> void:
	_fence(x0 + 0.5, z0 + 0.5, x1 - 0.5, z1 - 0.5)
	b("prop").box_yaw(Vector3((x0 + x1) * 0.5, CH + 1.3, z1 - 0.8), Vector3(2.2, 1.3, 0.08), 0.0, Mats.COL_DARK, 0x37)
	for k in 3:
		var p := Vector2(rng.randf_range(x0 + 2.0, x1 - 2.0), rng.randf_range(z0 + 2.0, z1 - 3.0))
		b("concrete").box_yaw(Vector3(p.x, CH + 0.35, p.y), Vector3(rng.randf_range(1.0, 2.0), 0.7, rng.randf_range(1.0, 2.0)), rng.randf() * TAU, Color.WHITE, 0x37)


func _fence(x0: float, z0: float, x1: float, z1: float) -> void:
	var post := b("prop")
	var h := 2.0
	var segs := [[x0, z0, x1, z0], [x1, z0, x1, z1], [x1, z1, x0, z1], [x0, z1, x0, z0]]
	for s in segs:
		var a := Vector2(s[0], s[1])
		var e := Vector2(s[2], s[3])
		var len := a.distance_to(e)
		var n := maxi(1, int(len / 4.0))
		var dir := (e - a).normalized()
		var yaw := atan2(-dir.y, dir.x)
		for i in n:
			var p := a.lerp(e, float(i) / float(n))
			post.box_yaw(Vector3(p.x, CH + h * 0.5, p.y), Vector3(0.07, h, 0.07), 0.0, Mats.COL_DARK, 0x37)
		var mid := (a + e) * 0.5
		for hh: float in [0.25, 1.95]:
			post.box_yaw(Vector3(mid.x, CH + hh, mid.y), Vector3(len, 0.04, 0.04), yaw, Mats.COL_DARK, 0x37)


func _containers(x0: float, z0: float, x1: float, z1: float, rect: Rect2) -> void:
	var pal := [Color(0.62, 0.17, 0.1), Color(0.15, 0.3, 0.5), Color(0.8, 0.55, 0.12), Color(0.2, 0.4, 0.28), Color(0.55, 0.55, 0.55)]
	for k in 2:
		var p := Vector2(rng.randf_range(x0 + 2.0, x1 - 2.0), rng.randf_range(z0 + 2.0, z1 - 2.0))
		if rect.grow(1.5).has_point(p):
			continue
		var yaw := 0.0 if rng.randf() < 0.5 else PI * 0.5
		var col: Color = pal[rng.randi() % pal.size()]
		var stack := rng.randi_range(1, 2)
		for s in stack:
			b("prop").box_yaw(Vector3(p.x, CH + 1.3 + 2.6 * float(s), p.y), Vector3(6.0, 2.6, 2.4), yaw, col, 0x37)


## Unclaimed land: a loose clump of trees on about half the tiles.
func _neutral_tile(o: Vector3, inst: Dictionary) -> void:
	if rng.randf() < 0.5:
		return
	var n := rng.randi_range(1, 3)
	var c := Vector2(o.x + rng.randf_range(8.0, P - 8.0), o.z + rng.randf_range(8.0, P - 8.0))
	for k in n:
		var p := c + Vector2(rng.randfn(0.0, 4.0), rng.randfn(0.0, 4.0))
		if p.x < o.x + 1.0 or p.x > o.x + P - 1.0 or p.y < o.z + 1.0 or p.y > o.z + P - 1.0:
			continue
		var v := rng.randi() % TREE_VARIANTS
		inst["trees"][v].append(_tree_xf(Vector3(p.x, 0, p.y), rng.randf_range(0.8, 1.3), -0.06))
		inst["tree_cols"][v].append(_leaf_col(1.0))


# ----------------------------------------------------------------- shared meshes
## [tree0, tree1, tree2, bush] ArrayMeshes: surface 0 trunk (bark), surface 1 foliage (bush: foliage only).
## Lighter blobs than the showcase (5 rings x 8 segments).
static func make_tree_meshes() -> Array:
	var out: Array = []
	var specs := [
		{"trunk_h": 3.4, "blobs": [[0, 4.6, 0, 2.2, 1.8], [1.3, 5.4, 0.4, 1.6, 1.4], [-1.2, 5.6, -0.6, 1.7, 1.4], [0.3, 6.6, 0.0, 1.5, 1.3]]},
		{"trunk_h": 2.6, "blobs": [[0, 5.2, 0, 1.4, 2.6], [0.5, 6.8, 0.2, 1.1, 1.8], [-0.4, 4.0, 0.3, 1.2, 1.5]]},
		{"trunk_h": 2.4, "blobs": [[0, 3.8, 0, 1.7, 1.5], [0.9, 4.3, 0.3, 1.2, 1.1], [-0.8, 4.4, -0.4, 1.2, 1.1]]},
	]
	var sd := 3.0
	for spec in specs:
		var trunk = MB.new()
		var foliage = MB.new()
		var th: float = spec["trunk_h"]
		trunk.lathe(Vector3.ZERO, [Vector2(0.30, 0.0), Vector2(0.22, 0.6), Vector2(0.17, th), Vector2(0.12, th + 1.4)], 8, Color(0.24, 0.17, 0.12))
		for bl in spec["blobs"]:
			ShowcaseProps._blob(foliage, Vector3(bl[0], bl[1], bl[2]), Vector3(bl[3], bl[4], bl[3]), 5, 8, sd, Color(0.38, 0.4, 0.35), Color(1.0, 1.0, 0.95))
			sd += 1.7
		var mesh := ArrayMesh.new()
		trunk.commit(mesh)
		foliage.commit(mesh)
		out.append(mesh)
	var bf = MB.new()
	ShowcaseProps._blob(bf, Vector3(0, 0.55, 0), Vector3(0.9, 0.7, 0.9), 5, 8, 9.0, Color(0.35, 0.38, 0.32), Color(1.0, 1.0, 0.95))
	var bm := ArrayMesh.new()
	bf.commit(bm)
	out.append(bm)
	return out


static func make_car_meshes() -> Array:
	var out: Array = []
	for v in CAR_KITS:
		out.append(CarKit.make(v))
	return out

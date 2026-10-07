extends RefCounted
## Procedural buildings for the live client, adapted from showcase building_builder.gd.
## Same three facade languages and tier heights:
##   R  punched windows, brick or plaster, string courses, balconies, pitched roofs on tier 0
##   C  shopfronts with awnings and signs (tier 0), ribbon-glazed offices (tier 1), glass towers (tier 2)
##   I  corrugated cladding, strip windows, roller doors, sawtooth roofs, stacks and tanks
## Changes for the live client: one tile is built at a time into its own batch set (BlockView
## caches it by zone / tier / road mask and merges per block); small finishes share the `prop`
## and `vcol` vertex-colour materials; fewer balconies, AC units and roof clutter, coarser lathes,
## no solar panels. Window state is not baked here: the facade COLOR alpha is rewritten at merge.

const Cfg := preload("res://client/assets/techart/live/scripts/live_cfg.gd")
const LB := preload("res://client/assets/techart/live/scripts/live_batch.gd")
const Mats := preload("res://client/assets/techart/live/scripts/live_mats.gd")
const SC := preload("res://shared/slice_constants.gd")

const H := Cfg.H
const P := Cfg.P
const CH := Cfg.CURB_H
const DIRV := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]

# ground-floor height factors, must match the facade materials in live_mats.gd
const GS_R := 1.0
const GS_C1 := 1.3
const GS_C2 := 1.4
const GS_I := 1.0

## Facade COLOR alpha placeholder; BlockView replaces it with the tile's window state.
const WINDOW_STATE_UNSET := 1.0

var D
var B: Dictionary = {}
var rng := RandomNumberGenerator.new()
## {center: Vector3, roof_y: float, size: Vector2, f: int, kind: String} of the tile just built.
var info := {}


func _init(data) -> void:
	D = data


func b(key: String) -> RefCounted:
	if not B.has(key):
		var m = LB.new()
		if key.begins_with("fac_"):
			m.use_custom0 = true
		B[key] = m
	return B[key]


static func right_of(v: Vector2) -> Vector2:
	return Vector2(v.y, -v.x)


## Per-tile descriptor in the showcase shape. Seed and default front come from the tile id, so
## the same lot always grows the same building.
static func descriptor(t: TileDelta, roads: int) -> Dictionary:
	return {
		"x": t.x, "z": t.y, "id": t.id,
		"owner": t.owner, "zone": t.zone, "has_building": t.has_building,
		"tier": clampi(t.building_tier, SC.BUILDING_TIER_MIN, SC.BUILDING_TIER_MAX),
		"roads": roads,
		"front": int(Cfg.hash01(t.id, 3) * 4.0) % 4,
		"seed": int(Cfg.hash01(t.id, 7) * 2147483000.0),
	}


## Cache key of the geometry a descriptor produces.
static func build_key(d: Dictionary) -> String:
	return "%d/%d/%d" % [int(d["zone"]), int(d["tier"]), int(d["roads"])]


## Builds one tile's building into fresh batches. Returns {"batches", "info"}; empty when the
## tile has no building.
func build_tile(t: Dictionary) -> Dictionary:
	B = {}
	info = {}
	if not t["has_building"] or t["zone"] == SC.Zone.NONE:
		return {}
	rng.seed = int(t["seed"])
	_building(t)
	return {"batches": B, "info": info}


# ------------------------------------------------------------------ placement
func _front_dir(t: Dictionary) -> int:
	var roads: int = t["roads"]
	var opts: Array = []
	for d in 4:
		if (roads >> d) & 1 == 1:
			opts.append(d)
	if opts.is_empty():
		return int(t["front"])
	return opts[rng.randi() % opts.size()]


func _lot_center(t: Dictionary) -> Vector2:
	var o := Cfg.corner(t["x"], t["z"])
	return Vector2(o.x + P * 0.5, o.z + P * 0.5)


func _building(t: Dictionary) -> void:
	var f := _front_dir(t)
	var c := _lot_center(t)
	var tier: int = t["tier"]
	match int(t["zone"]):
		SC.Zone.R:
			if tier == 0: _r0(t, c, f)
			elif tier == 1: _r1(t, c, f)
			else: _r2(t, c, f)
		SC.Zone.C:
			if tier == 0: _c0(t, c, f)
			elif tier == 1: _c1(t, c, f)
			else: _c2(t, c, f)
		SC.Zone.I:
			if tier == 0: _i0(t, c, f)
			elif tier == 1: _i1(t, c, f)
			else: _i2(t, c, f)


# ------------------------------------------------------------------ primitives
func wall(bt: RefCounted, a: Vector2, bp: Vector2, y0: float, y1: float, seed: float, floor_h: float,
		bay_w: float, door_flag: float, parapet: float, door_bay: float, variant: float) -> void:
	var W := a.distance_to(bp)
	var Ht := y1 - y0
	var dir := (bp - a).normalized()
	var n := Vector3(-dir.y, 0, dir.x)
	bt.quad(Vector3(a.x, y1, a.y), Vector3(bp.x, y1, bp.y), Vector3(bp.x, y0, bp.y), Vector3(a.x, y0, a.y), n,
		Vector2(0, -Ht), Vector2(W, -Ht), Vector2(W, 0), Vector2(0, 0),
		Color(seed, floor_h / 8.0, bay_w / 8.0, WINDOW_STATE_UNSET), Vector2(W, Ht), Color(door_flag, parapet / 4.0, door_bay, variant))


## Four facade walls around a rectangle. f = front direction index (door side).
func walls(key: String, c: Vector2, sl: float, sd: float, f: int, y0: float, y1: float, seed: float, floor_h: float,
		bay_w: float, door: bool, parapet: float, variant := 0.0) -> void:
	var bt := b(key)
	for k in 4:
		var d: Vector2 = DIRV[(f + k) % 4]
		var r := right_of(d)
		var parallel := (k % 2 == 0)
		var half := (sd if parallel else sl) * 0.5
		var span := (sl if parallel else sd)
		var a := c + d * half - r * (span * 0.5)
		var bp := c + d * half + r * (span * 0.5)
		var nb := maxf(1.0, floorf(span / bay_w + 0.5))
		var door_bay := floorf(nb * 0.5) if nb > 1.0 else 0.0
		wall(bt, a, bp, y0, y1, seed, floor_h, bay_w, 1.0 if (k == 0 and door) else 0.0, parapet, door_bay, variant)


## Flat roof slab with parapet inner faces and cap. y = roof level (top of last floor).
func flat_roof(c: Vector2, sl: float, sd: float, f: int, y: float, parapet: float, roof_key := "auto") -> void:
	if roof_key == "auto":
		var rr := rng.randf()
		roof_key = "roof_gravel" if rr < 0.5 else ("roof_membrane" if rr < 0.85 else "roof_green")
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var hx: Vector2 = r * (sl * 0.5)
	var hz: Vector2 = fd * (sd * 0.5)
	var wt := 0.25
	var rb := b(roof_key)
	var p0 := c - hx - hz
	var p1 := c + hx - hz
	var p2 := c + hx + hz
	var p3 := c - hx + hz
	var ax := hx.normalized() * (sl * 0.5 - wt)
	var az := hz.normalized() * (sd * 0.5 - wt)
	var q0 := c - ax - az
	var q1 := c + ax - az
	var q2 := c + ax + az
	var q3 := c - ax + az
	rb.quad(Vector3(q0.x, y, q0.y), Vector3(q1.x, y, q1.y), Vector3(q2.x, y, q2.y), Vector3(q3.x, y, q3.y), Vector3.UP,
		q0, q1, q2, q3)
	if parapet > 0.01:
		var cb := b("concrete")
		var qs := [q0, q1, q2, q3]
		for i in 4:
			var a: Vector2 = qs[i]
			var e: Vector2 = qs[(i + 1) % 4]
			var dir := (e - a).normalized()
			var nn := Vector3(-dir.y, 0, dir.x)
			var mid := (a + e) * 0.5
			if (Vector2(nn.x, nn.z)).dot(c - mid) < 0.0:
				nn = -nn
			cb.quad(Vector3(a.x, y + parapet, a.y), Vector3(e.x, y + parapet, e.y), Vector3(e.x, y, e.y), Vector3(a.x, y, a.y), nn,
				Vector2(0, -parapet), Vector2(a.distance_to(e), -parapet), Vector2(a.distance_to(e), 0), Vector2(0, 0))
		var outer := [p0, p1, p2, p3]
		for i in 4:
			var a2: Vector2 = outer[i]
			var e2: Vector2 = outer[(i + 1) % 4]
			var b2: Vector2 = qs[(i + 1) % 4]
			var a3: Vector2 = qs[i]
			cb.quad(Vector3(a2.x, y + parapet, a2.y), Vector3(e2.x, y + parapet, e2.y), Vector3(b2.x, y + parapet, b2.y), Vector3(a3.x, y + parapet, a3.y), Vector3.UP,
				a2, e2, b2, a3)


func cyl_at(key: String, c: Vector2, y0: float, radius: float, height: float, segs := 10, col := Color.WHITE, cap := true) -> void:
	var prof := [Vector2(radius, 0.0), Vector2(radius, height)]
	var bt := b(key)
	bt.lathe(Vector3(c.x, y0, c.y), prof, segs, col, 1.0)
	if cap:
		bt.lathe(Vector3(c.x, y0 + height, c.y), [Vector2(0.0, 0.0), Vector2(radius, 0.0)], segs, col, 1.0)


# ------------------------------------------------------------------ rooftop clutter
func hvac(c: Vector2, y: float, yaw: float) -> void:
	var w := rng.randf_range(1.4, 2.6)
	var d := rng.randf_range(0.9, 1.5)
	var h := rng.randf_range(0.8, 1.3)
	b("prop").box_yaw(Vector3(c.x, y + h * 0.5 + 0.18, c.y), Vector3(w, h, d), yaw, Color(0.93, 0.93, 0.92), 0x37)
	b("concrete").box_yaw(Vector3(c.x, y + 0.09, c.y), Vector3(w + 0.2, 0.18, d + 0.2), yaw, Color.WHITE, 0x37)
	var side := Vector3(-sin(yaw), 0, -cos(yaw))
	b("prop").box_yaw(Vector3(c.x, y + h * 0.5 + 0.18, c.y) + side * (d * 0.5 + 0.005), Vector3(w * 0.8, h * 0.45, 0.02), yaw, Mats.COL_EQUIP_GREY, 0x37)
	b("prop").box_yaw(Vector3(c.x, y + h + 0.19, c.y), Vector3(minf(w, d) * 0.7, 0.05, minf(w, d) * 0.7), yaw, Mats.COL_EQUIP_GREY, 0x37)


func vent_pipe(c: Vector2, y: float) -> void:
	cyl_at("prop", c, y, 0.14, rng.randf_range(0.8, 1.6), 8, Mats.COL_GALV)
	b("prop").lathe(Vector3(c.x, y + 1.4, c.y), [Vector2(0.14, 0.0), Vector2(0.28, 0.12), Vector2(0.28, 0.2), Vector2(0.0, 0.2)], 8, Mats.COL_GALV)


func penthouse(c: Vector2, y: float, w: float, d: float, h: float, yaw: float) -> void:
	b("concrete").box_yaw(Vector3(c.x, y + h * 0.5, c.y), Vector3(w, h, d), yaw, Color(0.9, 0.9, 0.88), 0x37, 1.0)
	b("prop").box_yaw(Vector3(c.x, y + h * 0.5, c.y) + Vector3(cos(yaw), 0, -sin(yaw)) * (w * 0.5 + 0.01), Vector3(0.05, h * 0.75, 1.1), yaw, Mats.COL_DARK, 0x37)


func antenna(c: Vector2, y: float, hgt: float) -> void:
	cyl_at("prop", c, y, 0.06, hgt, 6, Mats.COL_GALV, false)
	for k in 3:
		var yy := y + hgt * (0.55 + 0.15 * k)
		b("prop").box_yaw(Vector3(c.x, yy, c.y), Vector3(1.2 - 0.25 * k, 0.04, 0.04), float(k) * 0.9, Mats.COL_GALV, 0x37)
	b("emit").box_yaw(Vector3(c.x, y + hgt + 0.1, c.y), Vector3(0.14, 0.14, 0.14), 0.0, Color(1.0, 0.1, 0.05, 1.0), 0x37)


func dish(c: Vector2, y: float, yaw: float) -> void:
	cyl_at("prop", c, y, 0.04, 0.7, 6, Mats.COL_GALV, false)
	var pos := Vector3(c.x, y + 0.85, c.y)
	var prof := [Vector2(0.0, 0.0), Vector2(0.22, 0.04), Vector2(0.4, 0.14), Vector2(0.55, 0.3)]
	var tmp = LB.new()
	tmp.lathe(Vector3.ZERO, prof, 10, Color(0.85, 0.86, 0.88))
	var xf := Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, deg_to_rad(-65.0)), pos)
	b("prop").append_transformed(tmp, xf)


func water_tank(c: Vector2, y: float) -> void:
	for dx: float in [-0.9, 0.9]:
		for dz: float in [-0.9, 0.9]:
			cyl_at("prop", c + Vector2(dx, dz), y, 0.06, 1.4, 6, Mats.COL_DARK, false)
	b("prop").box_yaw(Vector3(c.x, y + 1.42, c.y), Vector3(2.2, 0.08, 2.2), 0.0, Mats.COL_DARK, 0x37)
	b("prop").lathe(Vector3(c.x, y + 1.46, c.y), [Vector2(1.05, 0.0), Vector2(1.05, 2.0)], 12, Mats.COL_RUST)
	b("prop").lathe(Vector3(c.x, y + 3.46, c.y), [Vector2(0.0, 0.0), Vector2(1.05, 0.0), Vector2(0.9, 0.35), Vector2(0.0, 0.5)], 12, Mats.COL_RUST)


## Scatter roof clutter inside the roof rectangle, keeping a clear disc at the centre for the faction badge.
func roof_clutter(c: Vector2, sl: float, sd: float, f: int, y: float, density: float, kinds: Array) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var n := int(density * sl * sd / 40.0)
	for i in n:
		var a := rng.randf_range(-0.5, 0.5) * (sl - 2.4)
		var bb := rng.randf_range(-0.5, 0.5) * (sd - 2.4)
		var p := c + r * a + fd * bb
		if p.distance_to(c) < 3.6:
			continue
		var k: String = kinds[rng.randi() % kinds.size()]
		var yaw := atan2(r.y, r.x) * -1.0
		match k:
			"hvac": hvac(p, y, yaw)
			"vent": vent_pipe(p, y)
			"pent": penthouse(p, y, rng.randf_range(2.2, 3.4), rng.randf_range(2.2, 3.0), rng.randf_range(2.4, 3.0), yaw)
			"dish": dish(p, y, rng.randf_range(0, TAU))
			"antenna": antenna(p, y, rng.randf_range(3.0, 6.0))
			"tank": water_tank(p, y)


# ------------------------------------------------------------------ canopies / awnings / signs
func canopy(c: Vector2, f: int, front_half: float, y: float, w: float, d: float) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var base := c + fd * (front_half + d * 0.5 - 0.05)
	var yaw := atan2(r.y, r.x) * -1.0
	b("prop").box_yaw(Vector3(base.x, y, base.y), Vector3(w, 0.16, d), yaw, Mats.COL_DARK, 0x37)
	b("concrete").box_yaw(Vector3(base.x, y + 0.12, base.y), Vector3(w + 0.1, 0.06, d + 0.1), yaw, Color.WHITE, 0x37)
	for s: float in [-1.0, 1.0]:
		var pp := base + r * (s * (w * 0.5 - 0.12)) + fd * (d * 0.5 - 0.15)
		cyl_at("prop", pp, CH, 0.06, y - CH, 6, Mats.COL_DARK, false)


func awning(c: Vector2, f: int, front_half: float, y_top: float, w: float, d: float, col: Color) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var p0 := c + fd * front_half - r * (w * 0.5)
	var p1 := c + fd * front_half + r * (w * 0.5)
	var q0 := p0 + fd * d
	var q1 := p1 + fd * d
	var drop := 0.55
	var bt := b("vcol")
	var nrm := Vector3(fd.x, 0.6, fd.y).normalized()
	bt.quad(Vector3(p0.x, y_top, p0.y), Vector3(p1.x, y_top, p1.y), Vector3(q1.x, y_top - drop, q1.y), Vector3(q0.x, y_top - drop, q0.y), nrm,
		Vector2(0, 0), Vector2(w, 0), Vector2(w, 1), Vector2(0, 1), col)
	bt.quad(Vector3(q0.x, y_top - drop, q0.y), Vector3(q1.x, y_top - drop, q1.y), Vector3(q1.x, y_top - drop - 0.22, q1.y), Vector3(q0.x, y_top - drop - 0.22, q0.y), Vector3(fd.x, 0, fd.y),
		Vector2(0, 0), Vector2(w, 0), Vector2(w, 0.2), Vector2(0, 0.2), col * 0.9)


func sign_panel(c: Vector2, f: int, front_half: float, y: float, w: float, h: float, col: Color) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var p0 := c + fd * (front_half + 0.08) - r * (w * 0.5)
	var p1 := c + fd * (front_half + 0.08) + r * (w * 0.5)
	b("emit").quad(Vector3(p0.x, y + h, p0.y), Vector3(p1.x, y + h, p1.y), Vector3(p1.x, y, p1.y), Vector3(p0.x, y, p0.y), Vector3(fd.x, 0, fd.y),
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), col)
	var yaw := atan2(r.y, r.x) * -1.0
	var cc := c + fd * (front_half + 0.04)
	b("prop").box_yaw(Vector3(cc.x, y + h * 0.5, cc.y), Vector3(w + 0.16, h + 0.16, 0.08), yaw, Mats.COL_DARK, 0x37)


func ac_unit(wall_pt: Vector2, fd: Vector2, y: float) -> void:
	var yaw := atan2(right_of(fd).y, right_of(fd).x) * -1.0
	var c := wall_pt + fd * 0.28
	b("prop").box_yaw(Vector3(c.x, y + 0.2, c.y), Vector3(0.75, 0.4, 0.5), yaw, Mats.COL_EQUIP_WHITE, 0x37)
	b("prop").box_yaw(Vector3((c + fd * 0.255).x, y + 0.2, (c + fd * 0.255).y), Vector3(0.5, 0.3, 0.02), yaw, Mats.COL_DARK, 0x37)


func balcony(c: Vector2, f: int, front_half: float, y: float, w: float, d: float) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var base := c + fd * (front_half + d * 0.5)
	var yaw := atan2(r.y, r.x) * -1.0
	b("concrete").box_yaw(Vector3(base.x, y, base.y), Vector3(w, 0.16, d), yaw, Color.WHITE, 0x37)
	var rail_h := 1.05
	var rail = b("prop")
	var edge := base + fd * (d * 0.5 - 0.03)
	b("glass_simple").box_yaw(Vector3(edge.x, y + 0.08 + rail_h * 0.5, edge.y), Vector3(w - 0.06, rail_h, 0.03), yaw, Color.WHITE, 0x37)
	rail.box_yaw(Vector3(edge.x, y + 0.08 + rail_h, edge.y), Vector3(w, 0.05, 0.05), yaw, Mats.COL_DARK, 0x37)
	for s: float in [-1.0, 1.0]:
		var sp: Vector2 = base + r * (s * (w * 0.5 - 0.03))
		rail.box_yaw(Vector3(sp.x, y + 0.08 + rail_h * 0.5, sp.y), Vector3(0.04, rail_h, d), yaw, Mats.COL_DARK, 0x37)


# ------------------------------------------------------------------ R : residential
func _r0(t: Dictionary, c0: Vector2, f: int) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var sl := rng.randf_range(8.5, 10.5)
	var sd := rng.randf_range(7.0, 8.6)
	var c := c0 - fd * 1.5 + r * rng.randf_range(-1.0, 1.0)
	var seed := rng.randf()
	var floors := 2
	var fh := 3.0
	var y0 := CH
	var eave := y0 + float(floors) * fh
	walls("fac_R_plaster", c, sl, sd, f, y0, eave, seed, fh, 3.2, true, 0.0, 0.0)
	var ridge_h := rng.randf_range(2.2, 2.9)
	_gable(c, sl, sd, f, eave, ridge_h, seed)
	var chim := c + r * (sl * 0.28) - fd * (sd * 0.15)
	b("brick").box_yaw(Vector3(chim.x, eave + ridge_h * 0.75, chim.y), Vector3(0.7, ridge_h * 1.0 + 0.4, 0.7), 0.0, Color.WHITE, 0x37, 1.0)
	b("concrete").box_yaw(Vector3(chim.x, eave + ridge_h * 1.28, chim.y), Vector3(0.85, 0.12, 0.85), 0.0, Color.WHITE, 0x37)
	canopy(c, f, sd * 0.5, y0 + 2.6, 2.4, 1.3)
	ac_unit(c + fd * (sd * 0.5) + r * (sl * 0.3), fd, y0 + 0.2)
	info = {"center": Vector3(c.x, eave + ridge_h, c.y), "roof_y": eave + ridge_h, "size": Vector2(sl, sd), "f": f, "kind": "R0"}


## Gable roof: ridge parallel to the lateral axis. Front and back slopes plus triangular gable ends.
func _gable(c: Vector2, sl: float, sd: float, f: int, y_eave: float, ridge_h: float, seed: float) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var ov := 0.45
	var hl := sl * 0.5 + ov
	var hd := sd * 0.5 + ov
	var rt := b("roof_tile")
	var y_e := y_eave - 0.05
	var y_r := y_eave + ridge_h
	var slope_len := sqrt(hd * hd + ridge_h * ridge_h)
	for s: float in [-1.0, 1.0]:
		var e0 := c + r * (-hl) + fd * (s * hd)
		var e1 := c + r * (hl) + fd * (s * hd)
		var g0 := c + r * (-hl)
		var g1 := c + r * (hl)
		var nrm := Vector3(fd.x * s * ridge_h / slope_len, hd / slope_len, fd.y * s * ridge_h / slope_len)
		rt.quad(Vector3(e0.x, y_e, e0.y), Vector3(e1.x, y_e, e1.y), Vector3(g1.x, y_r, g1.y), Vector3(g0.x, y_r, g0.y), nrm,
			Vector2(0, 0), Vector2(hl * 2.0, 0), Vector2(hl * 2.0, slope_len), Vector2(0, slope_len))
		var i0 := c + r * (-hl) + fd * (s * (hd - ov))
		var i1 := c + r * hl + fd * (s * (hd - ov))
		b("concrete").quad(Vector3(e1.x, y_e, e1.y), Vector3(e0.x, y_e, e0.y), Vector3(i0.x, y_e, i0.y), Vector3(i1.x, y_e, i1.y), Vector3.DOWN,
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	var wb := b("fac_R_plaster")
	for s: float in [-1.0, 1.0]:
		var base0 := c + r * (s * sl * 0.5) + fd * (-sd * 0.5)
		var base1 := c + r * (s * sl * 0.5) + fd * (sd * 0.5)
		var apex := c + r * (s * sl * 0.5)
		var nrm := Vector3(r.x * s, 0, r.y * s)
		var col := Color(seed, 3.0 / 8.0, 3.2 / 8.0, WINDOW_STATE_UNSET)
		var c0 := Color(0, 1.0, 0, 0)
		wb.tri(Vector3(base0.x, y_eave, base0.y), Vector3(base1.x, y_eave, base1.y), Vector3(apex.x, y_r, apex.y), nrm,
			Vector2(0, 0), Vector2(sd, 0), Vector2(sd * 0.5, -ridge_h), col, Vector2(sd, ridge_h), c0)


func _r1(t: Dictionary, c0: Vector2, f: int) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var sl := rng.randf_range(11.5, 13.2)
	var sd := rng.randf_range(10.5, 12.4)
	var c := c0 + r * rng.randf_range(-0.6, 0.6)
	var seed := rng.randf()
	var floors := rng.randi_range(4, 6)
	var fh := 3.1
	var y0 := CH
	var key := "fac_R_brick" if rng.randf() < 0.6 else "fac_R_plaster"
	var top := y0 + fh * GS_R + float(floors - 1) * fh
	var parapet := 0.9
	walls(key, c, sl, sd, f, y0, top + parapet, seed, fh, 3.4, true, parapet, 0.0)
	flat_roof(c, sl, sd, f, top, parapet)
	canopy(c, f, sd * 0.5, y0 + 2.9, 3.2, 1.6)
	_r_balconies(c, sl, sd, f, y0, floors, fh)
	_r_ac_units(c, sl, sd, f, y0, floors, fh)
	roof_clutter(c, sl, sd, f, top, 0.55, ["hvac", "vent", "pent", "dish", "tank"])
	info = {"center": Vector3(c.x, top, c.y), "roof_y": top, "size": Vector2(sl, sd), "f": f, "kind": "R1"}


func _r2(t: Dictionary, c0: Vector2, f: int) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var sl := rng.randf_range(11.5, 13.0)
	var sd := rng.randf_range(11.0, 12.8)
	var c := c0 + r * rng.randf_range(-0.5, 0.5)
	var seed := rng.randf()
	var fh := 3.1
	var floors := rng.randi_range(8, 11)
	var set_floors := 2
	var y0 := CH
	var key := "fac_R_plaster" if rng.randf() < 0.6 else "fac_R_brick"
	var main_floors := floors - set_floors
	var top1 := y0 + fh * GS_R + float(main_floors - 1) * fh
	var parapet := 0.7
	walls(key, c, sl, sd, f, y0, top1, seed, fh, 3.4, true, 0.0, 0.0)
	var sl2 := sl - 3.0
	var sd2 := sd - 3.0
	var top2 := top1 + float(set_floors) * fh
	flat_roof(c, sl, sd, f, top1, 0.0)
	_terrace_rail(c, sl, sd, f, top1)
	walls(key, c, sl2, sd2, f, top1, top2 + parapet, seed, fh, 3.4, false, parapet, 0.0)
	flat_roof(c, sl2, sd2, f, top2, parapet)
	canopy(c, f, sd * 0.5, y0 + 3.0, 3.6, 1.8)
	_r_balconies(c, sl, sd, f, y0, main_floors, fh)
	_r_ac_units(c, sl, sd, f, y0, main_floors, fh)
	roof_clutter(c, sl2, sd2, f, top2, 0.55, ["hvac", "vent", "pent", "antenna", "dish", "tank"])
	info = {"center": Vector3(c.x, top2, c.y), "roof_y": top2, "size": Vector2(sl2, sd2), "f": f, "kind": "R2"}


func _terrace_rail(c: Vector2, sl: float, sd: float, f: int, y: float) -> void:
	for k in 4:
		var d: Vector2 = DIRV[(f + k) % 4]
		var rr := right_of(d)
		var parallel := (k % 2 == 0)
		var half := (sd if parallel else sl) * 0.5 - 0.15
		var span := (sl if parallel else sd) - 0.3
		var pos := c + d * half
		var yw := atan2(rr.y, rr.x) * -1.0
		b("prop").box_yaw(Vector3(pos.x, y + 1.0, pos.y), Vector3(span, 0.05, 0.05), yw, Mats.COL_DARK, 0x37)
		b("glass_simple").box_yaw(Vector3(pos.x, y + 0.5, pos.y), Vector3(span, 0.95, 0.03), yw, Color.WHITE, 0x37)


func _r_balconies(c: Vector2, sl: float, sd: float, f: int, y0: float, floors: int, fh: float) -> void:
	var nb := maxf(1.0, floorf(sl / 3.4 + 0.5))
	var bw := sl / nb
	for fl in range(1, floors):
		for bi in int(nb):
			if rng.randf() < 0.62:
				continue
			var lat := -sl * 0.5 + (float(bi) + 0.5) * bw
			var r := right_of(DIRV[f])
			var cc := c + r * lat
			balcony(cc, f, sd * 0.5, y0 + fh * GS_R + float(fl - 1) * fh + 0.02, bw * 0.62, 1.2)


func _r_ac_units(c: Vector2, sl: float, sd: float, f: int, y0: float, floors: int, fh: float) -> void:
	for k in range(1, 4):
		var d: Vector2 = DIRV[(f + k) % 4]
		var rr := right_of(d)
		var parallel := (k % 2 == 0)
		var half := (sd if parallel else sl) * 0.5
		var span := (sl if parallel else sd)
		var nb := maxf(1.0, floorf(span / 3.4 + 0.5))
		var bw := span / nb
		for fl in range(1, floors):
			for bi in int(nb):
				if rng.randf() < 0.92:
					continue
				var lat := -span * 0.5 + (float(bi) + 0.5) * bw + bw * 0.28
				var wp := c + d * half + rr * lat
				ac_unit(wp, d, y0 + fh * GS_R + float(fl - 1) * fh + 0.3)


# ------------------------------------------------------------------ C : commercial
func _c0(t: Dictionary, c0: Vector2, f: int) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var sl := rng.randf_range(13.0, 14.6)
	var sd := rng.randf_range(10.5, 12.5)
	var c := c0 + r * rng.randf_range(-0.4, 0.4)
	var seed := rng.randf()
	var floors := rng.randi_range(2, 3)
	var fh := 3.6
	var y0 := CH
	var top := y0 + fh * GS_C1 + float(floors - 1) * fh
	var parapet := 1.0
	walls("fac_C_ribbon", c, sl, sd, f, y0, top + parapet, seed, fh, 3.4, true, parapet, 0.0)
	flat_roof(c, sl, sd, f, top, parapet)
	var nb := maxf(1.0, floorf(sl / 3.4 + 0.5))
	var bw := sl / nb
	var pal := [Color(0.75, 0.15, 0.12), Color(0.12, 0.35, 0.55), Color(0.15, 0.45, 0.25), Color(0.85, 0.65, 0.12), Color(0.35, 0.18, 0.4)]
	for bi in int(nb):
		var lat := -sl * 0.5 + (float(bi) + 0.5) * bw
		var pc := c + r * lat
		if bi != int(floorf(nb * 0.5)):
			awning(pc, f, sd * 0.5, y0 + fh * GS_C1 - 0.5, bw - 0.3, 1.2, pal[(bi + int(seed * 7.0)) % pal.size()])
		else:
			canopy(pc, f, sd * 0.5, y0 + 3.2, 2.6, 1.4)
		var sc: Color = pal[(bi * 2 + int(seed * 11.0)) % pal.size()].lightened(0.35)
		sc.a = 1.0
		sign_panel(pc, f, sd * 0.5, y0 + fh * GS_C1 + 0.2, bw - 0.9, 0.7, sc)
	roof_clutter(c, sl, sd, f, top, 0.6, ["hvac", "hvac", "vent", "pent", "antenna"])
	info = {"center": Vector3(c.x, top, c.y), "roof_y": top, "size": Vector2(sl, sd), "f": f, "kind": "C0"}


func _c1(t: Dictionary, c0: Vector2, f: int) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var sl := rng.randf_range(12.5, 14.4)
	var sd := rng.randf_range(12.0, 14.0)
	var c := c0 + r * rng.randf_range(-0.4, 0.4)
	var seed := rng.randf()
	var floors := rng.randi_range(5, 8)
	var fh := 3.7
	var y0 := CH
	var top := y0 + fh * GS_C1 + float(floors - 1) * fh
	var parapet := 1.1
	walls("fac_C_ribbon", c, sl, sd, f, y0, top + parapet, seed, fh, 3.4, true, parapet, 0.0)
	flat_roof(c, sl, sd, f, top, parapet)
	canopy(c, f, sd * 0.5, y0 + 3.6, 4.2, 2.0)
	var nb := maxf(1.0, floorf(sl / 3.4 + 0.5))
	var bw := sl / nb
	for bi in int(nb) + 1:
		var lat := -sl * 0.5 + float(bi) * bw
		var pp := c + fd * (sd * 0.5 + 0.18) + r * lat
		var yaw := atan2(r.y, r.x) * -1.0
		b("concrete").box_yaw(Vector3(pp.x, (y0 + top) * 0.5 + 1.5, pp.y), Vector3(0.1, top - y0 - 3.0, 0.36), yaw, Color(0.95, 0.95, 0.93), 0x37)
	roof_clutter(c, sl, sd, f, top, 0.6, ["hvac", "hvac", "pent", "antenna", "dish"])
	info = {"center": Vector3(c.x, top, c.y), "roof_y": top, "size": Vector2(sl, sd), "f": f, "kind": "C1"}


func _c2(t: Dictionary, c0: Vector2, f: int) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var seed := rng.randf()
	var y0 := CH
	var pod_l := rng.randf_range(13.6, 14.8)
	var pod_d := rng.randf_range(13.0, 14.4)
	var c := c0 + r * rng.randf_range(-0.2, 0.2)
	var fh := 4.0
	var pod_floors := 3
	var pod_top := y0 + fh * GS_C1 + float(pod_floors - 1) * fh
	walls("fac_C_ribbon", c, pod_l, pod_d, f, y0, pod_top, seed, fh, 3.4, true, 0.0, 0.0)
	flat_roof(c, pod_l, pod_d, f, pod_top, 0.0)
	_terrace_rail(c, pod_l, pod_d, f, pod_top)
	canopy(c, f, pod_d * 0.5, y0 + 3.8, 5.0, 2.2)
	var sk0 := c + fd * (pod_d * 0.5 + 0.06) - r * (pod_l * 0.5 - 0.3)
	var sk1 := c + fd * (pod_d * 0.5 + 0.06) + r * (pod_l * 0.5 - 0.3)
	b("glass_simple").quad(Vector3(sk0.x, y0 + fh * 1.4 - 0.4, sk0.y), Vector3(sk1.x, y0 + fh * 1.4 - 0.4, sk1.y), Vector3(sk1.x, y0 + 0.3, sk1.y), Vector3(sk0.x, y0 + 0.3, sk0.y), Vector3(fd.x, 0, fd.y),
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	var tl := pod_l - rng.randf_range(3.0, 4.5)
	var td := pod_d - rng.randf_range(3.0, 4.5)
	var tfloors := rng.randi_range(12, 20)
	var tfh := 3.9
	var tcenter := c - fd * rng.randf_range(0.0, 1.2) + r * rng.randf_range(-0.6, 0.6)
	var ttop := pod_top + tfh * float(tfloors)
	walls("fac_C_curtain", tcenter, tl, td, f, pod_top, ttop, seed, tfh, 1.5, false, 0.0, 1.0)
	flat_roof(tcenter, tl, td, f, ttop, 0.0, "concrete")
	var ml := tl - 3.0
	var md := td - 3.0
	var mh := rng.randf_range(4.0, 6.0)
	walls("fac_C_ribbon", tcenter, ml, md, f, ttop, ttop + mh, seed + 0.3, 3.0, 4.0, false, mh, 0.0)
	flat_roof(tcenter, ml, md, f, ttop + mh, 0.4, "roof_gravel")
	antenna(tcenter, ttop + mh, rng.randf_range(12.0, 22.0))
	for k in 3:
		hvac(tcenter + r * rng.randf_range(-0.5, 0.5) * (tl - 3.0), ttop + mh + 0.4, 0.0)
	info = {"center": Vector3(tcenter.x, ttop + mh, tcenter.y), "roof_y": ttop + mh, "size": Vector2(ml, md), "f": f, "kind": "C2"}


# ------------------------------------------------------------------ I : industrial
func _i0(t: Dictionary, c0: Vector2, f: int) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var sl := rng.randf_range(13.0, 14.6)
	var sd := rng.randf_range(10.5, 12.2)
	var c := c0 - fd * 0.8
	var seed := rng.randf()
	var hall_h := 7.0 + rng.randf() * 1.2
	var y0 := CH
	walls("fac_I", c, sl, sd, f, y0, y0 + hall_h, seed, 5.2, 4.8, true, 0.0, rng.randf())
	_corrugated_gable(c, sl, sd, f, y0 + hall_h, 1.4)
	canopy(c, f, sd * 0.5, y0 + 4.6, 5.6, 2.4)
	for k in 2:
		vent_pipe(c + r * (-3.0 + 6.0 * float(k)) - fd * 1.0, y0 + hall_h + 1.0)
	info = {"center": Vector3(c.x, y0 + hall_h + 1.4, c.y), "roof_y": y0 + hall_h + 1.4, "size": Vector2(sl, sd), "f": f, "kind": "I0"}


func _corrugated_gable(c: Vector2, sl: float, sd: float, f: int, y_eave: float, ridge_h: float) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var ov := 0.3
	var hl := sl * 0.5 + ov
	var hd := sd * 0.5 + ov
	var rt := b("roof_metal")
	var y_r := y_eave + ridge_h
	var slope_len := sqrt(hd * hd + ridge_h * ridge_h)
	for s: float in [-1.0, 1.0]:
		var e0 := c + r * (-hl) + fd * (s * hd)
		var e1 := c + r * (hl) + fd * (s * hd)
		var g0 := c + r * (-hl)
		var g1 := c + r * (hl)
		var nrm := Vector3(fd.x * s * ridge_h / slope_len, hd / slope_len, fd.y * s * ridge_h / slope_len)
		rt.quad(Vector3(e0.x, y_eave, e0.y), Vector3(e1.x, y_eave, e1.y), Vector3(g1.x, y_r, g1.y), Vector3(g0.x, y_r, g0.y), nrm,
			Vector2(0, 0), Vector2(hl * 2.0, 0), Vector2(hl * 2.0, slope_len), Vector2(0, slope_len))
	var wb := b("fac_I")
	for s: float in [-1.0, 1.0]:
		var base0 := c + r * (s * sl * 0.5) + fd * (-sd * 0.5)
		var base1 := c + r * (s * sl * 0.5) + fd * (sd * 0.5)
		var apex := c + r * (s * sl * 0.5)
		var nrm := Vector3(r.x * s, 0, r.y * s)
		wb.tri(Vector3(base0.x, y_eave, base0.y), Vector3(base1.x, y_eave, base1.y), Vector3(apex.x, y_r, apex.y), nrm,
			Vector2(0, 0), Vector2(sd, 0), Vector2(sd * 0.5, -ridge_h), Color(0.5, 5.2 / 8.0, 4.8 / 8.0, WINDOW_STATE_UNSET), Vector2(sd, ridge_h), Color(0, 1.0, 0, 0))


func _sawtooth(c: Vector2, sl: float, sd: float, f: int, y: float, teeth: int) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var pitch := sd / float(teeth)
	var rise := 1.8
	var rt := b("roof_metal")
	var gt := b("glass_simple")
	for k in teeth:
		var z0 := -sd * 0.5 + pitch * float(k)
		var z1 := z0 + pitch
		var p00 := c + r * (-sl * 0.5) + fd * z0
		var p01 := c + r * (sl * 0.5) + fd * z0
		var p10 := c + r * (-sl * 0.5) + fd * z1
		var p11 := c + r * (sl * 0.5) + fd * z1
		var slope := sqrt(pitch * pitch + rise * rise)
		var n_s := Vector3(-fd.x * rise / slope, pitch / slope, -fd.y * rise / slope)
		rt.quad(Vector3(p00.x, y + rise, p00.y), Vector3(p01.x, y + rise, p01.y), Vector3(p11.x, y, p11.y), Vector3(p10.x, y, p10.y), n_s,
			Vector2(0, 0), Vector2(sl, 0), Vector2(sl, slope), Vector2(0, slope))
		gt.quad(Vector3(p00.x, y, p00.y), Vector3(p01.x, y, p01.y), Vector3(p01.x, y + rise, p01.y), Vector3(p00.x, y + rise, p00.y), Vector3(fd.x, 0, fd.y),
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))


func _stack(c: Vector2, y: float, h: float, r0: float) -> void:
	var prof := [Vector2(r0, 0.0), Vector2(r0 * 0.78, h * 0.7), Vector2(r0 * 0.66, h)]
	b("brick_stack").lathe(Vector3(c.x, y, c.y), prof, 12, Color.WHITE, 0.4)
	b("vcol").lathe(Vector3(c.x, y + h * 0.88, c.y), [Vector2(r0 * 0.69, 0.0), Vector2(r0 * 0.68, h * 0.06)], 12, Color(0.8, 0.1, 0.08))
	b("vcol").lathe(Vector3(c.x, y + h * 0.94, c.y), [Vector2(r0 * 0.665, 0.0), Vector2(r0 * 0.655, h * 0.06)], 12, Color(0.9, 0.9, 0.9))
	b("concrete").lathe(Vector3(c.x, y + h, c.y), [Vector2(r0 * 0.72, 0.0), Vector2(r0 * 0.72, 0.3), Vector2(r0 * 0.5, 0.3)], 12)
	b("emit").box_yaw(Vector3(c.x, y + h + 0.6, c.y), Vector3(0.18, 0.18, 0.18), 0.0, Color(1, 0.1, 0.05, 1.0), 0x37)


func _tank(c: Vector2, y: float, rad: float, h: float, col: Color) -> void:
	b("prop").lathe(Vector3(c.x, y, c.y), [Vector2(rad, 0.0), Vector2(rad, h)], 14, col, 0.3)
	b("prop").lathe(Vector3(c.x, y + h, c.y), [Vector2(0.0, 0.0), Vector2(rad * 0.98, 0.0), Vector2(rad, 0.15), Vector2(rad * 0.7, 0.55), Vector2(0.0, 0.7)], 14, col, 0.3)
	b("prop").box_yaw(Vector3(c.x + rad + 0.05, y + h * 0.5, c.y), Vector3(0.05, h, 0.4), 0.0, Mats.COL_DARK, 0x37)
	b("prop").lathe(Vector3(c.x, y + h * 0.42, c.y), [Vector2(rad + 0.02, 0.0), Vector2(rad + 0.04, 0.12)], 14, Mats.COL_DARK)


func _i1(t: Dictionary, c0: Vector2, f: int) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var sl := rng.randf_range(13.0, 14.6)
	var sd := rng.randf_range(8.5, 9.6)
	var c := c0 - fd * 2.6 + r * rng.randf_range(-0.3, 0.3)
	var seed := rng.randf()
	var hall_h := 9.0 + rng.randf() * 1.5
	var y0 := CH
	walls("fac_I", c, sl, sd, f, y0, y0 + hall_h, seed, 5.2, 4.8, true, 0.0, rng.randf())
	_sawtooth(c, sl, sd, f, y0 + hall_h, 3)
	var ol := 5.2
	var od := 5.4
	var oc := c + r * (sl * 0.5 - ol * 0.5) + fd * (sd * 0.5 + od * 0.5)
	var otop := y0 + 3.4 * 3.0
	walls("fac_C_ribbon", oc, ol, od, f, y0, otop + 0.8, seed + 0.4, 3.4, 3.0, true, 0.8, 0.0)
	flat_roof(oc, ol, od, f, otop, 0.8)
	var sc := c - r * (sl * 0.5 - 1.8) - fd * (sd * 0.5 + 2.4)
	_stack(sc, CH, 26.0 + rng.randf() * 6.0, 1.5)
	for k in 2:
		var tp := c + r * (-3.5 + 5.0 * float(k)) + fd * (sd * 0.5 + 3.2 + 0.6 * float(k))
		_tank(tp, CH, 2.0, 6.0 - float(k), [Color(0.82, 0.83, 0.85), Color(0.68, 0.72, 0.75)][k])
	vent_pipe(c + r * 3.0, y0 + hall_h + 2.0)
	info = {"center": Vector3(c.x, y0 + hall_h + 1.8, c.y), "roof_y": y0 + hall_h + 1.8, "size": Vector2(sl, sd), "f": f, "kind": "I1"}


func _i2(t: Dictionary, c0: Vector2, f: int) -> void:
	var fd: Vector2 = DIRV[f]
	var r := right_of(fd)
	var sl := rng.randf_range(13.2, 14.8)
	var sd := rng.randf_range(9.0, 10.5)
	var c := c0 - fd * 2.2
	var seed := rng.randf()
	var hall_h := 11.0 + rng.randf() * 2.0
	var y0 := CH
	walls("fac_I", c, sl, sd, f, y0, y0 + hall_h, seed, 5.5, 4.8, true, 0.0, rng.randf())
	_corrugated_gable(c, sl, sd, f, y0 + hall_h, 2.2)
	var pl := 6.0
	var pd := 6.0
	var pc := c - r * (sl * 0.5 - pl * 0.5 - 0.2) - fd * (sd * 0.5 - pd * 0.5)
	var ph := hall_h + 9.0
	walls("fac_I", pc, pl, pd, f, y0, y0 + ph, seed + 0.2, 5.5, 3.0, false, 0.0, 0.3)
	flat_roof(pc, pl, pd, f, y0 + ph, 0.0, "roof_gravel")
	b("prop").box_yaw(Vector3(pc.x, y0 + ph + 1.2, pc.y), Vector3(2.6, 2.4, 2.6), 0.0, Mats.COL_GALV, 0x37)
	_stack(c + r * (sl * 0.5 - 1.5) + fd * (sd * 0.5 + 3.0), CH, 38.0, 1.8)
	_stack(c + r * (sl * 0.5 - 4.6) + fd * (sd * 0.5 + 3.4), CH, 30.0, 1.4)
	for k in 3:
		var tp := c - r * (sl * 0.5 - 2.2 - 4.0 * float(k)) + fd * (sd * 0.5 + 3.3)
		_tank(tp, CH, 1.8, 7.0 - float(k) * 0.8, [Color(0.82, 0.83, 0.85), Color(0.72, 0.5, 0.35), Color(0.82, 0.83, 0.85)][k])
	var pipe_y := CH + 5.0
	var pa := pc + fd * (pd * 0.5)
	var pb := c + r * (sl * 0.5 - 2.0) + fd * (sd * 0.5 + 3.3)
	var ang := atan2(pb.y - pa.y, pb.x - pa.x)
	var mid := (pa + pb) * 0.5
	b("prop").box_yaw(Vector3(mid.x, pipe_y, mid.y), Vector3(pa.distance_to(pb), 0.35, 0.35), -ang, Mats.COL_GALV, 0x37)
	info = {"center": Vector3(pc.x, y0 + ph + 2.4, pc.y), "roof_y": y0 + ph + 2.4, "size": Vector2(pl, pd), "f": f, "kind": "I2"}

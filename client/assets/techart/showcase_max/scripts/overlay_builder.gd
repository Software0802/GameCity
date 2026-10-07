extends RefCounted
## Game overlay layer (palette from docs/briefs/art-visual-source.md): zone lot plates, faction brackets,
## territory border + curtain, roof badges (A hexagon, B diamond), power coverage, congestion pulse, grid.
## Separate thin geometry on its own materials. Never bakes colour into world albedo.

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")
const MB := preload("res://client/assets/techart/showcase_max/scripts/mesh_batch.gd")
const SC := preload("res://shared/slice_constants.gd")

const H := Cfg.H
const P := Cfg.P
const C := Cfg.C
const CH := Cfg.CURB_H

var D
var B: Dictionary
var infos: Dictionary

func _init(data, batches: Dictionary, building_infos: Dictionary) -> void:
	D = data
	B = batches
	infos = building_infos

func b(key: String) -> RefCounted:
	if not B.has(key):
		B[key] = MB.new()
	return B[key]

## Palette slots. Vertex colour r = slot / 15, a = alpha. The overlay shader looks the slot up in a per-preset
## table of tonemap-compensated colours (see tonemap_model.gd), so the final image shows the palette hex values.
const PAL_A := 0
const PAL_A_DIM := 1
const PAL_B := 2
const PAL_B_DIM := 3
const PAL_R := 4
const PAL_C := 5
const PAL_I := 6
const PAL_POWER := 7
const PAL_CONG := 8

## Target colours (brief: art-visual-source.md). Index = slot.
static func palette() -> Array:
	return [Cfg.COL_FACTION_A, Color("1AAF7C"), Cfg.COL_FACTION_B, Color("C93A55"),
		Cfg.COL_ZONE_R, Cfg.COL_ZONE_C, Cfg.COL_ZONE_I, Cfg.COL_POWER, Cfg.COL_CONGESTION]

static func pal(slot: int, a := 1.0) -> Color:
	return Color(float(slot) / 15.0, 0.0, 0.0, a)

static func faction_col(o: int) -> Color:
	return pal(PAL_A if o == SC.Owner.FACTION_A else PAL_B)

static func faction_dim(o: int) -> Color:
	return pal(PAL_A_DIM if o == SC.Owner.FACTION_A else PAL_B_DIM)

static func zone_col(z: int) -> Color:
	match z:
		SC.Zone.R: return pal(PAL_R)
		SC.Zone.C: return pal(PAL_C)
		SC.Zone.I: return pal(PAL_I)
	return Color(0, 0, 0, 0)

func build() -> void:
	_lots()
	_territory()
	_power()
	_congestion()
	_badges()

func _flat_rect(bt: RefCounted, x0: float, z0: float, x1: float, z1: float, y: float, col: Color) -> void:
	bt.quad(Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), Vector3.UP,
		Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1), col)

func _lots() -> void:
	var plate := b("ov_zone")
	var br := b("ov_bracket")
	for tz in D.n:
		for tx in D.n:
			var t: Dictionary = D.tile(tx, tz)
			if t["owner"] == SC.Owner.NEUTRAL:
				continue
			var o: Vector3 = Cfg.corner(tx, tz)
			var x0 := o.x + H
			var z0 := o.z + H
			var x1 := o.x + P - H
			var z1 := o.z + P - H
			if t["zone"] != SC.Zone.NONE:
				var zc := zone_col(t["zone"])
				zc.a = 0.30
				_flat_rect(plate, x0, z0, x1, z1, CH + 0.05, zc)
				# zone frame: a solid band around the lot edge so the land-use colour survives roofs and trees
				var fr := zone_col(t["zone"])
				fr.a = 0.92
				var fw := 0.9
				var zf := b("ov_zone_frame")
				_flat_rect(zf, x0, z0, x1, z0 + fw, CH + 0.07, fr)
				_flat_rect(zf, x0, z1 - fw, x1, z1, CH + 0.07, fr)
				_flat_rect(zf, x0, z0 + fw, x0 + fw, z1 - fw, CH + 0.07, fr)
				_flat_rect(zf, x1 - fw, z0 + fw, x1, z1 - fw, CH + 0.07, fr)
			# faction corner brackets
			var fc := faction_col(t["owner"])
			fc.a = 1.0
			var y := CH + 0.09
			var w := 0.42
			var leg := 3.2
			var ins := 0.45
			for sx: float in [-1.0, 1.0]:
				for sz: float in [-1.0, 1.0]:
					var cx := (x0 + ins) if sx < 0 else (x1 - ins)
					var cz := (z0 + ins) if sz < 0 else (z1 - ins)
					_flat_rect(br, minf(cx, cx - sx * leg), cz - w * 0.5, maxf(cx, cx - sx * leg), cz + w * 0.5, y, fc)
					_flat_rect(br, cx - w * 0.5, minf(cz, cz - sz * leg), cx + w * 0.5, maxf(cz, cz - sz * leg), y, fc)

func _territory() -> void:
	var line := b("ov_border")
	var wall := b("ov_curtain")
	var wh := 7.0
	var hw := 0.5
	for tz in D.n:
		for tx in D.n:
			var t: Dictionary = D.tile(tx, tz)
			if t["owner"] == SC.Owner.NEUTRAL:
				continue
			var o: Vector3 = Cfg.corner(tx, tz)
			var col := faction_col(t["owner"])
			for d in 4:
				var dv: Vector2i = D.DIRS[d]
				var nx: int = tx + dv.x
				var nz: int = tz + dv.y
				if not D.in_bounds(nx, nz):
					continue
				var nt: Dictionary = D.tile(nx, nz)
				if nt["owner"] == t["owner"]:
					continue
				var a: Vector2
				var e: Vector2
				match d:
					0: a = Vector2(o.x, o.z); e = Vector2(o.x + P, o.z)
					1: a = Vector2(o.x + P, o.z); e = Vector2(o.x + P, o.z + P)
					2: a = Vector2(o.x, o.z + P); e = Vector2(o.x + P, o.z + P)
					_: a = Vector2(o.x, o.z); e = Vector2(o.x, o.z + P)
				var dir := (e - a).normalized()
				var nrm := Vector2(-dir.y, dir.x)
				var ext := dir * hw
				var p0 := a - ext
				var p1 := e + ext
				var s := col
				s.a = 0.95
				line.quad(Vector3((p0 - nrm * hw).x, 0.22, (p0 - nrm * hw).y), Vector3((p1 - nrm * hw).x, 0.22, (p1 - nrm * hw).y),
					Vector3((p1 + nrm * hw).x, 0.22, (p1 + nrm * hw).y), Vector3((p0 + nrm * hw).x, 0.22, (p0 + nrm * hw).y), Vector3.UP,
					Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), s)
				var cc := col
				cc.a = 0.42
				var L := p0.distance_to(p1)
				wall.quad(Vector3(p0.x, 0.22 + wh, p0.y), Vector3(p1.x, 0.22 + wh, p1.y), Vector3(p1.x, 0.22, p1.y), Vector3(p0.x, 0.22, p0.y), Vector3(nrm.x, 0, nrm.y),
					Vector2(0, 1), Vector2(L, 1), Vector2(L, 0), Vector2(0, 0), cc)

func _power() -> void:
	var fill := b("ov_power")
	var ring := b("ov_ring")
	var pc := pal(PAL_POWER)
	for t in D.tiles:
		if not t["power_covered"]:
			continue
		var o: Vector3 = Cfg.corner(t["x"], t["z"])
		var c := pc
		c.a = 0.034
		_flat_rect(fill, o.x + 0.8, o.z + 0.8, o.x + P - 0.8, o.z + P - 0.8, 0.26, c)
	var rr := float(SC.POWER_RADIUS_SUGGESTED) * P
	for pl in D.plants:
		var tc: Vector3 = Cfg.tile_center(pl["tile"].x, pl["tile"].y)
		var segs := 160
		var w := 0.38
		var run := 0.0
		for i in segs:
			var a0 := TAU * float(i) / float(segs)
			var a1 := TAU * float(i + 1) / float(segs)
			var p0 := Vector2(cos(a0), sin(a0))
			var p1 := Vector2(cos(a1), sin(a1))
			var seg_len := (p1 - p0).length() * rr
			var c := pc
			c.a = 0.7
			ring.quad(Vector3(tc.x + p0.x * (rr - w), 0.3, tc.z + p0.y * (rr - w)), Vector3(tc.x + p1.x * (rr - w), 0.3, tc.z + p1.y * (rr - w)),
				Vector3(tc.x + p1.x * (rr + w), 0.3, tc.z + p1.y * (rr + w)), Vector3(tc.x + p0.x * (rr + w), 0.3, tc.z + p0.y * (rr + w)), Vector3.UP,
				Vector2(run, 0), Vector2(run + seg_len, 0), Vector2(run + seg_len, 1), Vector2(run, 1), c)
			run += seg_len

func _congestion() -> void:
	var pulse := b("ov_pulse")
	for e in D.hot_edges:
		var a: Vector2i = e["a"]
		var bb: Vector2i = e["b"]
		var cong: float = e["congestion"]
		var vertical := (a.y == bb.y)       # edge between (x,z) and (x+1,z): vertical border line
		var line := maxi(a.x, bb.x) if vertical else maxi(a.y, bb.y)
		var along := a.y if vertical else a.x
		var c0: Vector3 = Cfg.corner(line, along) if vertical else Cfg.corner(along, line)
		var c1: Vector3 = Cfg.corner(line, along + 1) if vertical else Cfg.corner(along + 1, line)
		# strips just inside both curbs, covering the segment plus both junction squares
		for side: float in [-1.0, 1.0]:
			var col := pal(PAL_CONG)
			col.a = clampf(cong, 0.3, 1.0)
			var off: float = side * (C - 0.75)
			var wdt := 1.3
			var L := c0.distance_to(c1)
			if vertical:
				var x := c0.x + off
				pulse.quad(Vector3(x - wdt * 0.5, 0.06, c0.z), Vector3(x + wdt * 0.5, 0.06, c0.z), Vector3(x + wdt * 0.5, 0.06, c1.z), Vector3(x - wdt * 0.5, 0.06, c1.z), Vector3.UP,
					Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), col)
			else:
				var z := c0.z + off
				pulse.quad(Vector3(c0.x, 0.06, z - wdt * 0.5), Vector3(c1.x, 0.06, z - wdt * 0.5), Vector3(c1.x, 0.06, z + wdt * 0.5), Vector3(c0.x, 0.06, z + wdt * 0.5), Vector3.UP,
					Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), col)
		# soft glow across the carriageway
		var glow := pal(PAL_CONG)
		glow.a = 0.10 * cong
		if vertical:
			var x2 := c0.x
			pulse.quad(Vector3(x2 - C, 0.05, c0.z), Vector3(x2 + C, 0.05, c0.z), Vector3(x2 + C, 0.05, c1.z), Vector3(x2 - C, 0.05, c1.z), Vector3.UP,
				Vector2(0, 0.5), Vector2(0, 0.5), Vector2(1, 0.5), Vector2(1, 0.5), glow)
		else:
			var z2 := c0.z
			pulse.quad(Vector3(c0.x, 0.05, z2 - C), Vector3(c1.x, 0.05, z2 - C), Vector3(c1.x, 0.05, z2 + C), Vector3(c0.x, 0.05, z2 + C), Vector3.UP,
				Vector2(0, 0.5), Vector2(1, 0.5), Vector2(1, 0.5), Vector2(0, 0.5), glow)

func _badges() -> void:
	var fillb := b("ov_badge")
	var rimb := b("ov_badge_rim")
	for t in D.tiles:
		if t["owner"] == SC.Owner.NEUTRAL or not t["has_building"]:
			continue
		if not infos.has(t["id"]):
			continue
		var inf: Dictionary = infos[t["id"]]
		var c3: Vector3 = inf["center"]
		var y: float = c3.y + 0.55
		var o: int = t["owner"]
		var bright := faction_col(o)
		bright.a = 1.0
		var dim := faction_dim(o)
		dim.a = 1.0
		var sz: Vector2 = inf["size"]
		var rad := clampf(minf(sz.x, sz.y) * 0.17, 1.5, 2.5)
		if o == SC.Owner.FACTION_A:
			_ngon(rimb, c3.x, c3.z, y, rad + 0.4, 6, 0.0, dim)
			_ngon(fillb, c3.x, c3.z, y + 0.04, rad, 6, 0.0, bright)
		else:
			_ngon(rimb, c3.x, c3.z, y, (rad + 0.4) * 1.18, 4, PI * 0.25, dim)
			_ngon(fillb, c3.x, c3.z, y + 0.04, rad * 1.18, 4, PI * 0.25, bright)
		# short mast so the badge reads from the oblique camera as well
		rimb.box(Vector3(c3.x - 0.12, c3.y, c3.z - 0.12), Vector3(c3.x + 0.12, y, c3.z + 0.12), dim, 0x37)

func _ngon(bt: RefCounted, cx: float, cz: float, y: float, r: float, n: int, rot: float, col: Color) -> void:
	for i in n:
		var a0 := rot + TAU * float(i) / float(n)
		var a1 := rot + TAU * float(i + 1) / float(n)
		var p0 := Vector3(cx + cos(a0) * r, y, cz + sin(a0) * r)
		var p1 := Vector3(cx + cos(a1) * r, y, cz + sin(a1) * r)
		bt.tri(Vector3(cx, y, cz), p0, p1, Vector3.UP, Vector2(cx, cz), Vector2(p0.x, p0.z), Vector2(p1.x, p1.z), col)

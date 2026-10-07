extends RefCounted
## Game overlay for one block, adapted from showcase overlay_builder.gd: zone lot plates and
## frames, faction corner brackets, territory border and curtain, power coverage, pollution haze,
## congestion pulse, roof badges (A hexagon, B diamond). Thin unshaded geometry on the live
## overlay shader; colours are palette slots (live_palette.gd), never world albedo.
##
## Per-tile pieces (plate, frame, brackets, fields, badge) come from tile_pieces() so BlockView
## can cache them per tile; build() adds the block-level pieces that span tiles (territory
## borders against the neighbour ring, congestion pulses on the edges this block owns).

const Cfg := preload("res://client/assets/techart/live/scripts/live_cfg.gd")
const LB := preload("res://client/assets/techart/live/scripts/live_batch.gd")
const Pal := preload("res://client/assets/techart/live/scripts/live_palette.gd")
const SC := preload("res://shared/slice_constants.gd")

const H := Cfg.H
const P := Cfg.P
const C := Cfg.C
const CH := Cfg.CURB_H
const DIRS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

const ALPHA_PLATE := 0.30
const ALPHA_FRAME := 0.92
const ALPHA_POWER := 0.12
const ALPHA_BROWNOUT := 0.45
const ALPHA_HAZE_MAX := 0.35
const ALPHA_CURTAIN := 0.30
const CURTAIN_H := 5.0
## Edges at or above this congestion get a pulse strip.
const PULSE_MIN := 0.05

var D
var B: Dictionary
## Counters for the view check.
var pulse_edges := 0
var border_pieces := 0


func _init(data, batches: Dictionary) -> void:
	D = data
	B = batches


func b(key: String) -> RefCounted:
	if not B.has(key):
		B[key] = LB.new()
	return B[key]


static func _bt(batches: Dictionary, key: String) -> RefCounted:
	if not batches.has(key):
		batches[key] = LB.new()
	return batches[key]


static func _flat_rect(bt: RefCounted, x0: float, z0: float, x1: float, z1: float, y: float, col: Color) -> void:
	bt.quad(Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), Vector3.UP,
		Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1), col)


## Cache key of the per-tile pieces: everything tile_pieces() reads from the tile.
static func tile_key(t: TileDelta, has_info: bool) -> String:
	return "%d/%d/%d/%d/%d/%d/%d/%d" % [t.owner, t.zone, t.building_tier, 1 if t.has_building else 0,
		1 if t.power_covered else 0, 1 if t.brownout else 0, roundi(clampf(t.pollution, 0.0, 1.0) * 16.0), 1 if has_info else 0]


## Zone plate and frame, faction brackets, power / brownout / haze fields and the roof badge of
## one tile. Returns {key: LiveBatch}; keys ov_flat, ov_field, ov_brownout, ov_badge.
static func tile_pieces(t: TileDelta, info: Dictionary) -> Dictionary:
	var out := {}
	var o := Cfg.corner(t.x, t.y)
	if t.owner != SC.Owner.NEUTRAL:
		var flat := _bt(out, "ov_flat")
		var x0 := o.x + H
		var z0 := o.z + H
		var x1 := o.x + P - H
		var z1 := o.z + P - H
		if t.zone != SC.Zone.NONE:
			var dense := t.has_building and t.building_tier >= SC.BUILDING_TIER_MAX
			var slot := Pal.zone_slot(t.zone, dense)
			_flat_rect(flat, x0, z0, x1, z1, CH + 0.05, Pal.slot(slot, ALPHA_PLATE))
			var fr := Pal.slot(slot, ALPHA_FRAME)
			var fw := 0.9
			_flat_rect(flat, x0, z0, x1, z0 + fw, CH + 0.07, fr)
			_flat_rect(flat, x0, z1 - fw, x1, z1, CH + 0.07, fr)
			_flat_rect(flat, x0, z0 + fw, x0 + fw, z1 - fw, CH + 0.07, fr)
			_flat_rect(flat, x1 - fw, z0 + fw, x1, z1 - fw, CH + 0.07, fr)
		var fc := Pal.slot(Pal.faction_slot(t.owner), 1.0)
		var yb := CH + 0.09
		var w := 0.42
		var leg := 3.2
		var ins := 0.45
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				var cx := (x0 + ins) if sx < 0 else (x1 - ins)
				var cz := (z0 + ins) if sz < 0 else (z1 - ins)
				_flat_rect(flat, minf(cx, cx - sx * leg), cz - w * 0.5, maxf(cx, cx - sx * leg), cz + w * 0.5, yb, fc)
				_flat_rect(flat, cx - w * 0.5, minf(cz, cz - sz * leg), cx + w * 0.5, maxf(cz, cz - sz * leg), yb, fc)
	if t.power_covered:
		if t.brownout:
			_flat_rect(_bt(out, "ov_brownout"), o.x + 0.8, o.z + 0.8, o.x + P - 0.8, o.z + P - 0.8, 0.26, Pal.slot(Pal.SLOT_POWER, ALPHA_BROWNOUT))
		else:
			_flat_rect(_bt(out, "ov_field"), o.x + 0.8, o.z + 0.8, o.x + P - 0.8, o.z + P - 0.8, 0.26, Pal.slot(Pal.SLOT_POWER, ALPHA_POWER))
	if t.pollution > 0.01:
		var a := clampf(t.pollution, 0.0, 1.0) * ALPHA_HAZE_MAX
		_flat_rect(_bt(out, "ov_field"), o.x + 0.3, o.z + 0.3, o.x + P - 0.3, o.z + P - 0.3, 0.28, Pal.slot(Pal.SLOT_I_DENSE, a))
	if t.owner != SC.Owner.NEUTRAL and t.has_building and not info.is_empty():
		var bt := _bt(out, "ov_badge")
		var c3: Vector3 = info["center"]
		var yb: float = c3.y + 0.55
		var bright := Pal.slot(Pal.faction_slot(t.owner), 1.0)
		var dim := Pal.slot(Pal.faction_dim_slot(t.owner), 1.0)
		var sz: Vector2 = info["size"]
		var rad := clampf(minf(sz.x, sz.y) * 0.17, 1.5, 2.5)
		if t.owner == SC.Owner.FACTION_A:
			_ngon(bt, c3.x, c3.z, yb, rad + 0.4, 6, 0.0, dim)
			_ngon(bt, c3.x, c3.z, yb + 0.04, rad, 6, 0.0, bright)
		else:
			_ngon(bt, c3.x, c3.z, yb, (rad + 0.4) * 1.18, 4, PI * 0.25, dim)
			_ngon(bt, c3.x, c3.z, yb + 0.04, rad * 1.18, 4, PI * 0.25, bright)
		bt.box(Vector3(c3.x - 0.12, c3.y, c3.z - 0.12), Vector3(c3.x + 0.12, yb, c3.z + 0.12), dim, 0x37)
	return out


## Block-level pieces: territory borders and congestion pulses.
func build() -> void:
	_territory()
	_congestion()


func _territory() -> void:
	var line := b("ov_flat")
	var wall := b("ov_curtain")
	var hw := 0.5
	for ty in D.BLOCK:
		for tx in D.BLOCK:
			var x: int = D.x0 + tx
			var y: int = D.y0 + ty
			var t: TileDelta = D.tile(x, y)
			if t.owner == SC.Owner.NEUTRAL:
				continue
			var o := Cfg.corner(x, y)
			for d in 4:
				var dv: Vector2i = DIRS[d]
				var nx: int = x + dv.x
				var ny: int = y + dv.y
				if not SC.in_map(nx, ny):
					continue
				var nt: TileDelta = D.tile(nx, ny)
				if nt.owner == t.owner:
					continue
				# Each tile draws its own side of the border, inset into its own lot, so a
				# two-faction frontier shows both colours side by side and no block draws twice.
				var a: Vector2
				var e: Vector2
				match d:
					0: a = Vector2(o.x, o.z); e = Vector2(o.x + P, o.z)
					1: a = Vector2(o.x + P, o.z); e = Vector2(o.x + P, o.z + P)
					2: a = Vector2(o.x, o.z + P); e = Vector2(o.x + P, o.z + P)
					_: a = Vector2(o.x, o.z); e = Vector2(o.x, o.z + P)
				var out := Vector2(float(dv.x), float(dv.y))
				var inward := -out
				var p0 := a + inward * hw
				var p1 := e + inward * hw
				var col := Pal.slot(Pal.faction_slot(t.owner), 0.95)
				line.quad(Vector3((p0 - inward * hw).x, 0.22, (p0 - inward * hw).y), Vector3((p1 - inward * hw).x, 0.22, (p1 - inward * hw).y),
					Vector3((p1 + inward * hw).x, 0.22, (p1 + inward * hw).y), Vector3((p0 + inward * hw).x, 0.22, (p0 + inward * hw).y), Vector3.UP,
					Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), col)
				var cc := Pal.slot(Pal.faction_slot(t.owner), ALPHA_CURTAIN)
				var L := p0.distance_to(p1)
				var c0 := a + inward * 0.25
				var c1 := e + inward * 0.25
				wall.quad(Vector3(c0.x, 0.22 + CURTAIN_H, c0.y), Vector3(c1.x, 0.22 + CURTAIN_H, c1.y), Vector3(c1.x, 0.22, c1.y), Vector3(c0.x, 0.22, c0.y), Vector3(out.x, 0, out.y),
					Vector2(0, 1), Vector2(L, 1), Vector2(L, 0), Vector2(0, 0), cc)
				border_pieces += 1


func _congestion() -> void:
	var pulse := b("ov_pulse")
	var x0: int = D.x0
	var y0: int = D.y0
	for i in range(x0 + 1, x0 + D.BLOCK + 1):
		for z in range(y0, y0 + D.BLOCK + 1):
			var e: EdgeDelta = D.edge_v(i, z)
			if e == null or e.congestion < PULSE_MIN or not D.owns_segment_v(i, z):
				continue
			_pulse(Cfg.corner(i, z), Cfg.corner(i, z + 1), true, e.congestion, pulse)
	for j in range(y0 + 1, y0 + D.BLOCK + 1):
		for x in range(x0, x0 + D.BLOCK + 1):
			var e: EdgeDelta = D.edge_h(x, j)
			if e == null or e.congestion < PULSE_MIN or not D.owns_segment_h(x, j):
				continue
			_pulse(Cfg.corner(x, j), Cfg.corner(x + 1, j), false, e.congestion, pulse)


func _pulse(c0: Vector3, c1: Vector3, vertical: bool, cong: float, pulse: RefCounted) -> void:
	pulse_edges += 1
	for side: float in [-1.0, 1.0]:
		var col := Pal.slot(Pal.SLOT_WARN, clampf(cong, 0.3, 1.0))
		var off: float = side * (C - 0.75)
		var wdt := 1.3
		if vertical:
			var x := c0.x + off
			pulse.quad(Vector3(x - wdt * 0.5, 0.06, c0.z), Vector3(x + wdt * 0.5, 0.06, c0.z), Vector3(x + wdt * 0.5, 0.06, c1.z), Vector3(x - wdt * 0.5, 0.06, c1.z), Vector3.UP,
				Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), col)
		else:
			var z := c0.z + off
			pulse.quad(Vector3(c0.x, 0.06, z - wdt * 0.5), Vector3(c1.x, 0.06, z - wdt * 0.5), Vector3(c1.x, 0.06, z + wdt * 0.5), Vector3(c0.x, 0.06, z + wdt * 0.5), Vector3.UP,
				Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), col)
	var glow := Pal.slot(Pal.SLOT_WARN, 0.10 * cong)
	if vertical:
		var x2 := c0.x
		pulse.quad(Vector3(x2 - C, 0.05, c0.z), Vector3(x2 + C, 0.05, c0.z), Vector3(x2 + C, 0.05, c1.z), Vector3(x2 - C, 0.05, c1.z), Vector3.UP,
			Vector2(0, 0.5), Vector2(0, 0.5), Vector2(1, 0.5), Vector2(1, 0.5), glow)
	else:
		var z2 := c0.z
		pulse.quad(Vector3(c0.x, 0.05, z2 - C), Vector3(c1.x, 0.05, z2 - C), Vector3(c1.x, 0.05, z2 + C), Vector3(c0.x, 0.05, z2 + C), Vector3.UP,
			Vector2(0, 0.5), Vector2(1, 0.5), Vector2(1, 0.5), Vector2(0, 0.5), glow)


static func _ngon(bt: RefCounted, cx: float, cz: float, y: float, r: float, n: int, rot: float, col: Color) -> void:
	for i in n:
		var a0 := rot + TAU * float(i) / float(n)
		var a1 := rot + TAU * float(i + 1) / float(n)
		var p0 := Vector3(cx + cos(a0) * r, y, cz + sin(a0) * r)
		var p1 := Vector3(cx + cos(a1) * r, y, cz + sin(a1) * r)
		bt.tri(Vector3(cx, y, cz), p0, p1, Vector3.UP, Vector2(cx, cz), Vector2(p0.x, p0.z), Vector2(p1.x, p1.z), col)

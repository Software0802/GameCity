extends RefCounted
## Game-shaped city data for the showcase district (a corner of the 64x64 map).
## Mirrors docs/briefs/world-vertical-slice.md: tile{owner, zone, hasBuilding, buildingTier, powerCovered},
## edge{a, b, capacity, congestion} with orthogonal 4-neighbour edges only, power radius 4.

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")
const SC := preload("res://shared/slice_constants.gd")

const DIR_N := 0
const DIR_E := 1
const DIR_S := 2
const DIR_W := 3
const DIRS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]

var n: int = Cfg.N
var tiles: Array = []              # n*n Dictionary, index z*n+x
var edges: Array = []              # {a: Vector2i, b: Vector2i, capacity: int, congestion: float}
var plants: Array = []             # {tile: Vector2i, owner: int}
var vr := PackedByteArray()        # border x=i between (i-1,z)-(i,z): index i*n+z, i in 0..n
var hr := PackedByteArray()        # border z=j between (x,j-1)-(x,j): index j*n+x, j in 0..n
var vr_cong := PackedFloat32Array()
var hr_cong := PackedFloat32Array()
var vr_cap := PackedByteArray()
var hr_cap := PackedByteArray()
var hot_edges: Array = []          # edges flagged for the congestion pulse (strongest first)
var core := {SC.Owner.FACTION_A: Vector2(5.5, 9.3), SC.Owner.FACTION_B: Vector2(13.3, 7.2)}

func _init(seed_value: int = 20261007) -> void:
	generate(seed_value)

func tile(x: int, z: int) -> Dictionary:
	return tiles[z * n + x]

func in_bounds(x: int, z: int) -> bool:
	return x >= 0 and z >= 0 and x < n and z < n

func road_v(i: int, z: int) -> bool:
	return i >= 1 and i < n and z >= 0 and z < n and vr[i * n + z] == 1

func road_h(x: int, j: int) -> bool:
	return j >= 1 and j < n and x >= 0 and x < n and hr[j * n + x] == 1

## Bit mask of roads around corner (i,j): 1=N 2=E 4=S 8=W.
func junction_arms(i: int, j: int) -> int:
	var m := 0
	if road_v(i, j - 1): m |= 1
	if road_h(i, j): m |= 2
	if road_v(i, j): m |= 4
	if road_h(i - 1, j): m |= 8
	return m

## Bit mask of the tile sides that border a road.
func tile_roads(x: int, z: int) -> int:
	var m := 0
	if road_h(x, z): m |= 1
	if road_v(x + 1, z): m |= 2
	if road_h(x, z + 1): m |= 4
	if road_v(x, z): m |= 8
	return m

func _set_edge(a: Vector2i, b: Vector2i, capacity: int, congestion: float) -> void:
	# Orthogonal neighbours only (|dx|+|dy| == 1).
	assert(absi(a.x - b.x) + absi(a.y - b.y) == 1)
	edges.append({"a": a, "b": b, "capacity": capacity, "congestion": congestion})
	if a.y == b.y:
		var i := maxi(a.x, b.x)
		vr[i * n + a.y] = 1
		vr_cong[i * n + a.y] = congestion
		vr_cap[i * n + a.y] = capacity
	else:
		var j := maxi(a.y, b.y)
		hr[j * n + a.x] = 1
		hr_cong[j * n + a.x] = congestion
		hr_cap[j * n + a.x] = capacity

func generate(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.23
	var noise2 := FastNoiseLite.new()
	noise2.seed = seed_value + 7
	noise2.frequency = 0.41
	tiles.clear()
	edges.clear()
	plants.clear()
	vr.resize((n + 1) * n)
	vr_cong.resize((n + 1) * n)
	vr_cap.resize((n + 1) * n)
	hr.resize((n + 1) * n)
	hr_cong.resize((n + 1) * n)
	hr_cap.resize((n + 1) * n)
	vr.fill(0)
	hr.fill(0)
	var radius := {SC.Owner.FACTION_A: 6.7, SC.Owner.FACTION_B: 5.9}
	var ind_dir := {SC.Owner.FACTION_A: Vector2(-0.8, 0.6).normalized(), SC.Owner.FACTION_B: Vector2(0.75, -0.65).normalized()}
	for z in n:
		for x in n:
			var t := {
				"x": x, "z": z, "id": SC.tile_id(x, z),
				"owner": SC.Owner.NEUTRAL, "zone": SC.Zone.NONE,
				"has_building": false, "tier": 0, "power_covered": false,
				"plant": false, "front": rng.randi_range(0, 3),
				"seed": rng.randi(), "d_core": 99.0, "kind": "land",
			}
			var p := Vector2(x + 0.5, z + 0.5)
			var best_score := -9.0
			var best_owner := SC.Owner.NEUTRAL
			var scores := {}
			for o in [SC.Owner.FACTION_A, SC.Owner.FACTION_B]:
				var d: float = p.distance_to(core[o])
				var s: float = 1.0 - d / float(radius[o]) + noise.get_noise_2d(x, z) * 0.32
				scores[o] = s
				if s > best_score:
					best_score = s
					best_owner = o
			if best_score > 0.0:
				# neutral buffer where the two claims nearly tie
				if scores[SC.Owner.FACTION_A] > 0.0 and scores[SC.Owner.FACTION_B] > 0.0 and absf(scores[SC.Owner.FACTION_A] - scores[SC.Owner.FACTION_B]) < 0.18:
					best_owner = SC.Owner.NEUTRAL
				t["owner"] = best_owner
			if t["owner"] != SC.Owner.NEUTRAL:
				var o: int = t["owner"]
				var d: float = p.distance_to(core[o])
				t["d_core"] = d
				var r := rng.randf()
				var jitter := noise2.get_noise_2d(x * 1.7, z * 1.7)
				var rel: Vector2 = (p - core[o])
				var toward_ind: float = rel.normalized().dot(ind_dir[o]) if d > 0.01 else 0.0
				var zone := SC.Zone.R
				if d < 2.3 + jitter * 0.9:
					zone = SC.Zone.C if r < 0.78 else SC.Zone.R
				elif toward_ind > 0.45 and d > 3.2:
					zone = SC.Zone.I if r < 0.85 else SC.Zone.R
				elif d < 4.6:
					zone = SC.Zone.R if r < 0.7 else (SC.Zone.C if r < 0.92 else SC.Zone.I)
				else:
					zone = SC.Zone.R if r < 0.82 else (SC.Zone.I if r < 0.92 else SC.Zone.C)
				if rng.randf() < 0.07:
					zone = SC.Zone.NONE
				t["zone"] = zone
				if zone != SC.Zone.NONE:
					t["has_building"] = rng.randf() < 0.93
					var tier := 0
					var tr := rng.randf() + jitter * 0.35
					if d < 2.6:
						tier = 2 if tr < 0.72 else 1
					elif d < 4.4:
						tier = 2 if tr < 0.16 else (1 if tr < 0.72 else 0)
					else:
						tier = 1 if tr < 0.3 else 0
					if zone == SC.Zone.I and tier == 2 and d > 5.0:
						tier = 1
					t["tier"] = tier
					t["kind"] = "zoned"
				else:
					t["kind"] = "park" if rng.randf() < 0.7 else "plaza"
			tiles.append(t)

	# Power plants: one near each core (west of it) and one on the industrial side.
	var plant_tiles := [Vector2i(7, 10), Vector2i(3, 12), Vector2i(12, 5), Vector2i(15, 8)]
	for pt in plant_tiles:
		var t: Dictionary = tile(pt.x, pt.y)
		if t["owner"] == SC.Owner.NEUTRAL:
			# fall back to the nearest owned tile of the expected faction
			var best := 99.0
			var bp: Vector2i = pt
			for q in tiles:
				if q["owner"] == SC.Owner.NEUTRAL or q["plant"]:
					continue
				var dd := Vector2(q["x"], q["z"]).distance_to(Vector2(pt))
				if dd < best:
					best = dd
					bp = Vector2i(q["x"], q["z"])
			pt = bp
			t = tile(pt.x, pt.y)
		t["plant"] = true
		t["zone"] = SC.Zone.NONE
		t["has_building"] = true
		t["tier"] = 0
		t["kind"] = "plant"
		plants.append({"tile": pt, "owner": t["owner"]})
	for t in tiles:
		if t["owner"] == SC.Owner.NEUTRAL:
			continue
		for pl in plants:
			if pl["owner"] != t["owner"]:
				continue
			var d := Vector2(t["x"], t["z"]).distance_to(Vector2(pl["tile"]))
			if d <= float(SC.POWER_RADIUS):
				t["power_covered"] = true
				break

	# Road edges: only between two tiles of the same faction. Both ends must be claimed.
	for z in n:
		for x in n:
			var a := tile(x, z)
			if a["owner"] == SC.Owner.NEUTRAL:
				continue
			for dir in [DIR_E, DIR_S]:
				var d: Vector2i = DIRS[dir]
				var nx := x + d.x
				var nz := z + d.y
				if not in_bounds(nx, nz):
					continue
				var b := tile(nx, nz)
				if b["owner"] != a["owner"]:
					continue
				var dist := minf(float(a["d_core"]), float(b["d_core"]))
				var p_edge := 0.93 if dist < 5.5 else 0.78
				# keep a handful of lots reachable only by walking (no edge) for variety
				if hash01(x, z, dir) > p_edge:
					continue
				var cap := 3 if dist < 3.0 else (2 if dist < 5.0 else 1)
				var cong := clampf(rng.randf() * 0.35, 0.0, 1.0)
				_set_edge(Vector2i(x, z), Vector2i(nx, nz), cap, cong)
	# Congestion hot spots on well-connected arterial edges.
	var cand: Array = []
	for e in edges:
		if e["capacity"] >= 2:
			cand.append(e)
	cand.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return hash01(p["a"].x, p["a"].y, p["b"].x + p["b"].y * 31) < hash01(q["a"].x, q["a"].y, q["b"].x + q["b"].y * 31))
	var hot := 0
	for e in cand:
		# Prefer edges near the A core so the pulse sits in the hero frame.
		var mid := (Vector2(e["a"]) + Vector2(e["b"])) * 0.5 + Vector2(0.5, 0.5)
		if mid.distance_to(core[SC.Owner.FACTION_A]) > 4.5:
			continue
		e["congestion"] = [1.0, 0.82, 0.66][hot]
		_set_edge_cong(e)
		hot_edges.append(e)
		hot += 1
		if hot >= 3:
			break

func _set_edge_cong(e: Dictionary) -> void:
	var a: Vector2i = e["a"]
	var b: Vector2i = e["b"]
	if a.y == b.y:
		vr_cong[maxi(a.x, b.x) * n + a.y] = e["congestion"]
	else:
		hr_cong[maxi(a.y, b.y) * n + a.x] = e["congestion"]

static func hash01(a: int, b: int = 0, c: int = 0) -> float:
	return Cfg.hash01(a, b, c)

func summary() -> String:
	var counts := {"A": 0, "B": 0, "N": 0, "R": 0, "C": 0, "I": 0, "bld": 0, "t2": 0, "pwr": 0}
	for t in tiles:
		match int(t["owner"]):
			SC.Owner.FACTION_A: counts["A"] += 1
			SC.Owner.FACTION_B: counts["B"] += 1
			_: counts["N"] += 1
		if t["has_building"]:
			counts["bld"] += 1
			if t["tier"] == 2:
				counts["t2"] += 1
		match int(t["zone"]):
			SC.Zone.R: counts["R"] += 1
			SC.Zone.C: counts["C"] += 1
			SC.Zone.I: counts["I"] += 1
		if t["power_covered"]:
			counts["pwr"] += 1
	return "tiles=%d edges=%d plants=%d hot=%d %s" % [tiles.size(), edges.size(), plants.size(), hot_edges.size(), str(counts)]

func ascii_map() -> String:
	var s := ""
	for z in n:
		var line := ""
		for x in n:
			var t := tile(x, z)
			var ch := "."
			if t["owner"] != SC.Owner.NEUTRAL:
				var zc: String = ["-", "R", "C", "I"][t["zone"]]
				ch = zc if t["owner"] == SC.Owner.FACTION_A else zc.to_lower()
				if t["plant"]:
					ch = "P"
			line += ch + (str(t["tier"]) if t["has_building"] else " ") + (">" if road_v(x + 1, z) else " ")
		s += line + "\n"
	return s

extends RefCounted

## The starter town every faction gets inside its 8×8 spawn block when a NEW round
## begins (WorldState.seed_starter_cities(); a restored save never calls it).
## Pure layout data: plan_for(origin) returns absolute tiles and edges, WorldState
## applies them without charging the treasury.
##
## Layout (block-relative, x right, y down; drawn for BLOCK = 8):
##
##        x  0 1 2 3 4 5 6 7
##     y0    # R # # # C # #        #  road tile without a building
##     y1    # . R # # R # R        R C I  tier-1 building on a road tile
##     y2    R R . R C . o #        P  power plant (covers the whole block)
##     y3    # # R P # . . #        o  empty lot with road access: zone it and
##     y4    # # C # # # # #           it grows (the lots left for the player)
##     y5    C . . o # . . I        .  bare tile, no road
##     y6    # . o # # . I #
##     y7    # R # # # I # #
##
## Roads: the 田 (outer ring + the cross at row/column CROSS) plus four short lanes
## (ring → hub → two lots) and one stub for the third factory. Buildings are only
## on road tiles with two empty road tiles between neighbouring buildings, lanes
## hang two buildings off a tier-0 hub, and the industry sits in the far corner.
## Those three rules come from the growth model: a tier-1 building needs every
## incident edge at load ≤ 1.5 (quantized congestion 1/8, satisfaction
## 0.9 × 0.875 = 0.79 ≥ SAT_UP) to rise, two adjacent buildings load their edge
## to 3 and never grow, and a factory pollutes residential tiles within
## POLLUTION_RADIUS below SAT_UP. 9 R / 4 C / 3 I keeps the demand triangle open at
## tier 1 (pop 27, jobs 24 C + 18 I) and after R and C reach tier 2 while the
## factories stay at tier 1 (pop 72, jobs 64 + 18), with slack for a few extra
## residential tiles. Load Σ (tier + 1) is 32 at the start and 45 fully grown.
##
## These are layout constants, not rules; they stay here on purpose (shared/ is
## frozen and SliceConstants holds rule numbers only).

## Side of the spawn block the layout is drawn for. Must equal WorldState.SPAWN_SIZE.
const BLOCK := 8
## Row and column of the cross streets.
const CROSS := 4
## Power plant, block-relative. Chebyshev radius POWER_RADIUS (4) from (3,3) spans
## [-1, 7]² and so the whole block.
const PLANT := Vector2i(3, 3)
## Lanes off the ring: [root on the ring, hub, lot, lot]. Lots left as Zone.NONE in
## the tables below stay empty (the "o" tiles).
const LANES: Array = [
	[Vector2i(3, 0), Vector2i(3, 1), Vector2i(2, 1), Vector2i(3, 2)],
	[Vector2i(6, 0), Vector2i(6, 1), Vector2i(5, 1), Vector2i(6, 2)],
	[Vector2i(0, 3), Vector2i(1, 3), Vector2i(1, 2), Vector2i(2, 3)],
	[Vector2i(3, 7), Vector2i(3, 6), Vector2i(2, 6), Vector2i(3, 5)],
]
## Single-edge stubs off the ring: [root on the ring, lot].
const STUBS: Array = [
	[Vector2i(6, 7), Vector2i(6, 6)],
]
const LOTS_R: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(7, 1), Vector2i(1, 7), Vector2i(0, 2),
	Vector2i(2, 1), Vector2i(3, 2), Vector2i(5, 1), Vector2i(1, 2), Vector2i(2, 3),
]
const LOTS_C: Array[Vector2i] = [
	Vector2i(5, 0), Vector2i(0, 5), Vector2i(2, 4), Vector2i(4, 2),
]
const LOTS_I: Array[Vector2i] = [
	Vector2i(7, 5), Vector2i(5, 7), Vector2i(6, 6),
]
## Every starter building begins at this tier.
const START_TIER := 1


## Absolute placement for one spawn block.
class Plan:
	extends RefCounted

	var origin: Vector2i = Vector2i.ZERO
	var plant: Vector2i = Vector2i.ZERO
	## [[Vector2i a, Vector2i b], ...] every edge orthogonal, both ends in the block.
	var edges: Array = []
	## [[Vector2i tile, int zone, int tier], ...]
	var lots: Array = []
	## Road-connected tiles left without a building.
	var empty_lots: Array[Vector2i] = []

	func building_count() -> int:
		return lots.size()

	func count_zone(zone: int) -> int:
		var total := 0
		for lot in lots:
			if int(lot[1]) == zone:
				total += 1
		return total

	## Σ (tier + 1) over the buildings: what the plant carries at the start.
	func power_load() -> int:
		var total := 0
		for lot in lots:
			total += int(lot[2]) + 1
		return total


static func plan_for(origin: Vector2i) -> Plan:
	var plan := Plan.new()
	plan.origin = origin
	plan.plant = origin + PLANT
	var last := BLOCK - 1
	for i in last:
		plan.edges.append([origin + Vector2i(i, 0), origin + Vector2i(i + 1, 0)])
		plan.edges.append([origin + Vector2i(last, i), origin + Vector2i(last, i + 1)])
		plan.edges.append([origin + Vector2i(i, last), origin + Vector2i(i + 1, last)])
		plan.edges.append([origin + Vector2i(0, i), origin + Vector2i(0, i + 1)])
		plan.edges.append([origin + Vector2i(i, CROSS), origin + Vector2i(i + 1, CROSS)])
		plan.edges.append([origin + Vector2i(CROSS, i), origin + Vector2i(CROSS, i + 1)])
	var road_lots: Dictionary = {}
	for lane in LANES:
		plan.edges.append([origin + lane[0], origin + lane[1]])
		plan.edges.append([origin + lane[1], origin + lane[2]])
		plan.edges.append([origin + lane[1], origin + lane[3]])
		road_lots[lane[2]] = true
		road_lots[lane[3]] = true
	for stub in STUBS:
		plan.edges.append([origin + stub[0], origin + stub[1]])
		road_lots[stub[1]] = true
	var zoned: Dictionary = {}
	for cell in LOTS_R:
		plan.lots.append([origin + cell, SliceConstants.Zone.R, START_TIER])
		zoned[cell] = true
	for cell in LOTS_C:
		plan.lots.append([origin + cell, SliceConstants.Zone.C, START_TIER])
		zoned[cell] = true
	for cell in LOTS_I:
		plan.lots.append([origin + cell, SliceConstants.Zone.I, START_TIER])
		zoned[cell] = true
	for cell in road_lots:
		if not zoned.has(cell):
			plan.empty_lots.append(origin + cell)
	return plan


## The same plan reflected inside its block (flip_x mirrors left-right, flip_y
## top-bottom). Reflection keeps every spacing rule, so the demo city can tile
## four orientations of the block without repeating itself exactly. Lots keep
## their zones and tiers.
static func mirrored(plan: Plan, flip_x: bool, flip_y: bool) -> Plan:
	var out := Plan.new()
	out.origin = plan.origin
	out.plant = _reflect(plan.origin, plan.plant, flip_x, flip_y)
	for edge in plan.edges:
		out.edges.append([
			_reflect(plan.origin, edge[0], flip_x, flip_y), _reflect(plan.origin, edge[1], flip_x, flip_y),
		])
	for lot in plan.lots:
		out.lots.append([_reflect(plan.origin, lot[0], flip_x, flip_y), int(lot[1]), int(lot[2])])
	for cell in plan.empty_lots:
		out.empty_lots.append(_reflect(plan.origin, cell, flip_x, flip_y))
	return out


static func _reflect(origin: Vector2i, cell: Vector2i, flip_x: bool, flip_y: bool) -> Vector2i:
	var rel := cell - origin
	if flip_x:
		rel.x = BLOCK - 1 - rel.x
	if flip_y:
		rel.y = BLOCK - 1 - rel.y
	return origin + rel


## The layout as text, one row per line (legend in the header comment).
static func ascii_map(plan: Plan) -> String:
	var grid: Array = []
	for _y in BLOCK:
		var row: Array = []
		for _x in BLOCK:
			row.append(".")
		grid.append(row)
	for edge in plan.edges:
		for end in [edge[0], edge[1]]:
			var rel: Vector2i = end - plan.origin
			grid[rel.y][rel.x] = "#"
	for cell in plan.empty_lots:
		var rel: Vector2i = cell - plan.origin
		grid[rel.y][rel.x] = "o"
	for lot in plan.lots:
		var rel: Vector2i = lot[0] - plan.origin
		match int(lot[1]):
			SliceConstants.Zone.R:
				grid[rel.y][rel.x] = "R"
			SliceConstants.Zone.C:
				grid[rel.y][rel.x] = "C"
			SliceConstants.Zone.I:
				grid[rel.y][rel.x] = "I"
	var plant_rel: Vector2i = plan.plant - plan.origin
	grid[plant_rel.y][plant_rel.x] = "P"
	var lines: PackedStringArray = PackedStringArray()
	for y in BLOCK:
		lines.append(" ".join(PackedStringArray(grid[y])))
	return "\n".join(lines)

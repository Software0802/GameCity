extends RefCounted
## Live-pack constants (M4): the showcase street section at game scale. Units are metres.
## One game tile (SliceConstants) is a P x P lot; the map origin is tile (0,0) at world (0,0),
## so tile (x, y) covers [x*P, (x+1)*P] along X and [y*P, (y+1)*P] along Z. Camera, picking
## and hover convert with to_world / to_tile below. Street widths copy showcase cfg.gd so the
## road shader (half_w / half_row / park_w) and the facade heights stay identical.

const SHOWCASE := "res://client/assets/techart/showcase_max"
const PACK := "res://client/assets/techart/live"

const P := 30.0                   # tile pitch
const C := 4.5                    # carriageway half width (2 x 2.0 parking + 2 x 2.5 lanes)
const PARK_W := 2.0               # parking lane width
const S := 2.8                    # sidewalk width
const H := C + S                  # half right-of-way
const LOT := P - 2.0 * H          # buildable lot edge
const CURB_H := 0.15
## Terrain quad extends this far beyond the map on every side so the oblique camera never sees sky.
const TERRAIN_MARGIN := 1500.0


static func corner(i: int, j: int) -> Vector3:
	return Vector3(i * P, 0.0, j * P)


static func tile_center(tx: int, tz: int) -> Vector3:
	return Vector3((tx + 0.5) * P, 0.0, (tz + 0.5) * P)


## World position of a tile centre on the ground plane.
static func to_world(cell: Vector2i) -> Vector3:
	return tile_center(cell.x, cell.y)


## Tile under a world position (not clamped to the map).
static func to_tile(world: Vector3) -> Vector2i:
	return Vector2i(floori(world.x / P), floori(world.z / P))


static func map_extent() -> float:
	return float(SliceConstants.MAP_SIZE) * P


static func hash01(a: int, b: int = 0, c: int = 0) -> float:
	var h: int = (a * 374761393 + b * 668265263 + c * 2147483647 + 1274126177) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	h = h ^ (h >> 16)
	return float(h & 0xffff) / 65535.0

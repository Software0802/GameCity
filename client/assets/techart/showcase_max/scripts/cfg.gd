extends RefCounted
## Showcase constants. Units are metres. One tile of the 64x64 map is a P x P lot.
## Road edges (a,b) between orthogonal neighbours are drawn along the shared tile border;
## the lot is the tile inset by H (half right-of-way) on every side.

const PACK := "res://client/assets/techart/showcase_max"
const M1 := "res://client/assets/techart/roads_interchange"
const PREVIEW_DIR := "res://client/assets/techart/showcase_max/preview"

const N := 18                     # district is N x N tiles (a corner of the 64x64 map)
const P := 30.0                   # tile pitch
const C := 4.5                    # carriageway half width (9.0 m: 2 x 2.0 parking + 2 x 2.5 lanes)
const PARK_W := 2.0               # parking lane width
const S := 2.8                    # sidewalk width
const H := C + S                  # half right-of-way
const LOT := P - 2.0 * H          # buildable lot edge
const CURB_H := 0.15
const WORLD_HALF := N * P * 0.5

# Palette from docs/briefs/art-visual-source.md (overlay layer only, never world albedo).
const COL_FACTION_A := Color("2EE6A8")
const COL_FACTION_B := Color("FF5C7A")
const COL_ZONE_R := Color("E8A05A")
const COL_ZONE_C := Color("5B8FD9")
const COL_ZONE_I := Color("8B7A5C")
const COL_POWER := Color("F5D76E")
const COL_CONGESTION := Color("F0C93A")

static func corner(i: int, j: int) -> Vector3:
	return Vector3((i - N * 0.5) * P, 0.0, (j - N * 0.5) * P)

static func tile_center(tx: int, tz: int) -> Vector3:
	return Vector3((tx + 0.5 - N * 0.5) * P, 0.0, (tz + 0.5 - N * 0.5) * P)

static func hash01(a: int, b: int = 0, c: int = 0) -> float:
	var h: int = (a * 374761393 + b * 668265263 + c * 2147483647 + 1274126177) & 0x7fffffff
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff
	h = h ^ (h >> 16)
	return float(h & 0xffff) / 65535.0

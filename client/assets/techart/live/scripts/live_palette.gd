extends RefCounted
## Overlay palette slots for the live client. The overlay shader reads slot = COLOR.r * 15 and
## looks the colour up in `pal[16]`, a table of tonemap-compensated linear colours so the final
## image shows the hex values from docs/briefs/art-visual-source.md after ACES + Adjustments.
## The compensation is the showcase inverse model (tonemap_model.gd), evaluated once at startup
## for the active tonemap parameters (LiveLighting.TM_PARAMS).

const TonemapModel := preload("res://client/assets/techart/showcase_max/scripts/tonemap_model.gd")

const SLOT_A := 0
const SLOT_A_DIM := 1
const SLOT_B := 2
const SLOT_B_DIM := 3
const SLOT_R := 4
const SLOT_C := 5
const SLOT_I := 6
const SLOT_POWER := 7
const SLOT_WARN := 8
const SLOT_R_DENSE := 9
const SLOT_C_DENSE := 10
const SLOT_I_DENSE := 11
const SLOT_UNCLAIMED := 12
const SLOT_GRASS := 13
const SLOT_HUD_TEXT := 14
const SLOT_COUNT := 15


## Target sRGB colours, index = slot.
static func targets() -> Array[Color]:
	return [
		Palette.FACTION_A, Palette.FACTION_A_DIM, Palette.FACTION_B, Palette.FACTION_B_DIM,
		Palette.ZONE_R, Palette.ZONE_C, Palette.ZONE_I, Palette.POWER, Palette.WARN,
		Palette.ZONE_R_DENSE, Palette.ZONE_C_DENSE, Palette.ZONE_I_DENSE,
		Palette.UNCLAIMED, Palette.GRASS, Palette.HUD_TEXT,
	]


## Linear colour that displays as `target` under the given [exposure, white, contrast, saturation].
static func compensate(target: Color, tm: Array) -> Vector3:
	var r: Dictionary = TonemapModel.inverse(target, float(tm[0]), float(tm[1]), float(tm[2]), float(tm[3]))
	return r["lin"]


## 16-entry table for the overlay shader `pal` uniform (unused slots stay white).
static func table(tm: Array) -> PackedVector3Array:
	var pal := PackedVector3Array()
	pal.resize(16)
	pal.fill(Vector3.ONE)
	var list := targets()
	for i in list.size():
		pal[i] = compensate(list[i], tm)
	return pal


## Vertex colour selecting a slot; alpha carries the overlay strength.
static func slot(index: int, a := 1.0) -> Color:
	return Color(float(index) / 15.0, 0.0, 0.0, a)


static func faction_slot(owner: int) -> int:
	return SLOT_A if owner == SliceConstants.Owner.FACTION_A else SLOT_B


static func faction_dim_slot(owner: int) -> int:
	return SLOT_A_DIM if owner == SliceConstants.Owner.FACTION_A else SLOT_B_DIM


static func zone_slot(zone: int, dense: bool) -> int:
	match zone:
		SliceConstants.Zone.R:
			return SLOT_R_DENSE if dense else SLOT_R
		SliceConstants.Zone.C:
			return SLOT_C_DENSE if dense else SLOT_C
		SliceConstants.Zone.I:
			return SLOT_I_DENSE if dense else SLOT_I
	return SLOT_GRASS

class_name Palette
extends RefCounted

## The locked palette from docs/briefs/art-visual-source.md. Every color the client
## draws comes from this table; faction colors are outlines and roof badges only and
## never replace the R / C / I fills.

# Terrain
const GROUND := Color("#2F3A34")
const UNCLAIMED := Color("#3D4A42")
const GRASS := Color("#4A5C52")

# Roads
const ASPHALT := Color("#3A3A3C")
const CURB := Color("#C8C4B8")
## Congestion, crisis pulse, and HUD warn share this value.
const WARN := Color("#F0C93A")

# Zones: main fill and dense roof.
const ZONE_R := Color("#E8A05A")
const ZONE_R_DENSE := Color("#C47A3A")
const ZONE_C := Color("#5B8FD9")
const ZONE_C_DENSE := Color("#3D6FB0")
const ZONE_I := Color("#8B7A5C")
const ZONE_I_DENSE := Color("#6B5A3E")

# Factions: bright and dimmed.
const FACTION_A := Color("#2EE6A8")
const FACTION_A_DIM := Color("#1AAF7C")
const FACTION_B := Color("#FF5C7A")
const FACTION_B_DIM := Color("#C93A55")

# Services
const POWER := Color("#F5D76E")

# Buildings
const WALL_LIGHT := Color("#D6D0C4")
const WALL_MID := Color("#9A9488")
const WALL_SHADE := Color("#5C574E")
const WINDOW := Color("#E8E2D6")

# HUD
const HUD_BG := Color("#12151A")
const HUD_TEXT := Color("#E8ECF0")
const HUD_TEXT_2 := Color("#8B939C")
const HUD_POSITIVE := FACTION_A
const HUD_NEGATIVE := FACTION_B


static func faction(owner: int) -> Color:
	match owner:
		SliceConstants.Owner.FACTION_A:
			return FACTION_A
		SliceConstants.Owner.FACTION_B:
			return FACTION_B
		_:
			return UNCLAIMED


static func faction_dim(owner: int) -> Color:
	match owner:
		SliceConstants.Owner.FACTION_A:
			return FACTION_A_DIM
		SliceConstants.Owner.FACTION_B:
			return FACTION_B_DIM
		_:
			return UNCLAIMED


static func zone(zone_id: int) -> Color:
	match zone_id:
		SliceConstants.Zone.R:
			return ZONE_R
		SliceConstants.Zone.C:
			return ZONE_C
		SliceConstants.Zone.I:
			return ZONE_I
		_:
			return GRASS


static func zone_dense(zone_id: int) -> Color:
	match zone_id:
		SliceConstants.Zone.R:
			return ZONE_R_DENSE
		SliceConstants.Zone.C:
			return ZONE_C_DENSE
		SliceConstants.Zone.I:
			return ZONE_I_DENSE
		_:
			return GRASS


static func with_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)


static func hex(color: Color) -> String:
	return "#" + color.to_html(false)


## Flat HUD panel style: solid color, rounded corners, uniform content margin.
static func panel_style(color: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(margin)
	return style

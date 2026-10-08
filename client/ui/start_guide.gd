class_name StartGuide
extends RefCounted

## Opening checklist for a new player: four steps on one lot outside the spawn block,
## evaluated live from the authoritative mirror (not the optimistic overlay, so a rejected
## command never flashes a tick). A step counts when some faction-owned tile outside the
## spawn block satisfies it and every step before it:
##   1 claimed      owner is this faction and the tile is not in WorldState.spawn_block
##   2 zoned        zone != NONE
##   3 road         an edge touches the tile (ClientSession.road_tile_ids)
##   4 power        power_covered
## When all four hold the panel shows DONE_TEXT for DONE_LINGER_MS and then dismisses
## itself; closing the panel does the same. Either way the dismissal is saved through
## ClientSettings so the guide does not come back on reconnect or the next launch.
## No UI in here; client/ui/hud.gd draws it and client/dev/session_check.gd tests it.

const STEP_COUNT := 4
const STEPS: Array[String] = [
	"Claim a neutral tile next to your land (tool 1)",
	"Zone it R, C or I (tools 2-4)",
	"Connect it to a road (tool 6)",
	"Cover it with power (tool 7)",
]
const TITLE := "Getting started"
const DONE_TEXT := "Buildings grow a tier when a lot has road, power and positive demand"
## Camera controls, one line under the steps (hud.gd). English like the rest of the HUD;
## 中文对照：滚轮缩放 · 右键拖动俯仰 · 中键拖动旋转 · V 街景 · F11 全屏。
const CONTROLS_HINT := "Wheel zoom · RMB drag tilt · MMB drag rotate · V street view · F11 fullscreen"
const DONE_LINGER_MS := 10000

var settings: ClientSettings = null
## Steps satisfied so far, 0..STEP_COUNT.
var progress: int = 0
var dismissed: bool = false
## Time.get_ticks_msec() when progress first reached STEP_COUNT; -1 while incomplete.
var completed_at_ms: int = -1


## Reads the saved dismissal. settings may be null (nothing is persisted then).
func setup(p_settings: ClientSettings) -> void:
	settings = p_settings
	dismissed = settings != null and settings.guide_dismissed


## Re-evaluates the steps and runs the completion timer. now_ms is Time.get_ticks_msec()
## (a parameter so the headless check can drive the clock).
func refresh(session: ClientSession, now_ms: int) -> void:
	progress = evaluate(session)
	if progress < STEP_COUNT:
		completed_at_ms = -1
		return
	if completed_at_ms < 0:
		completed_at_ms = now_ms
	elif now_ms - completed_at_ms >= DONE_LINGER_MS:
		dismiss()


func is_visible() -> bool:
	return not dismissed


func is_complete() -> bool:
	return progress >= STEP_COUNT


func step_done(index: int) -> bool:
	return index < progress


## Hides the guide for good and saves that.
func dismiss() -> void:
	dismissed = true
	if settings != null:
		settings.guide_dismissed = true
		var err := settings.save()
		if err != OK:
			push_warning("settings save failed: %s" % error_string(err))


## Highest step reached by any faction-owned tile outside the spawn block; 0 before the
## faction is known.
static func evaluate(session: ClientSession) -> int:
	if session == null or session.faction == SliceConstants.Owner.NEUTRAL:
		return 0
	var spawn_key := WorldState.spawn_block(session.faction).key()
	var road_tiles := session.road_tile_ids()
	var best := 0
	for tile in session.authoritative_tiles():
		if tile.owner != session.faction:
			continue
		if InterestId.from_tile(tile.x, tile.y).key() == spawn_key:
			continue
		var steps := 1
		if tile.zone != SliceConstants.Zone.NONE:
			steps = 2
			if road_tiles.has(tile.id):
				steps = 3
				if tile.power_covered:
					steps = 4
		best = maxi(best, steps)
		if best >= STEP_COUNT:
			break
	return best

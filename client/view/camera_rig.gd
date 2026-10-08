class_name CameraRig
extends Camera3D

## Game camera. Orthographic micro-oblique by default (art brief: 65° below the horizon, 25° off
## vertical) with a perspective street view on V. World units are metres, LiveCfg.P (30 m) per
## game tile; every public entry point speaks tiles and converts.
##
## State: `target` (ground point looked at), `size` (view height at the target in metres, the
## ortho size; in perspective the focus distance is derived from it so the framing stays about
## the same), `pitch_deg` (view direction below the horizon, PITCH_MIN..PITCH_MAX, a lower floor
## in perspective), `yaw_deg` (orbit around the target, 0 = looking north / -Z), `perspective`.
##
## Input handled here: the wheel zooms about the ground point under the pointer, a right drag
## tilts, a middle drag orbits, WASD and the screen edges pan, Q / E tilt, the left / right
## arrows orbit (all in _process), R resets pitch and yaw, V toggles the projection. A press
## that moves no more than DRAG_PX before release is a click, not a drag; PlayInput applies the
## same rule (is_drag) to the right-click tool cancel. Panning, picking and the zoom anchor use
## the ground plane y = 0 through the camera's actual projection (ground_point).
##
## Depth range: in orthographic projection [near, far] hugs the visible ground and the tallest
## building at every pitch, so directional shadows and SSAO work in that range and the clip
## planes never cut a tower at the near screen edge. In perspective the near plane is a small
## fraction of the focus distance and the far plane reaches the farthest visible ground, capped
## at PERSPECTIVE_FAR_MAX. LiveLighting reads shadow_near() / shadow_distance() for the sun.

signal block_changed(block_x: int, block_y: int)

const Cfg := preload("res://client/assets/techart/live/scripts/live_cfg.gd")

const TILE := Cfg.P
## 3 tiles: one lot fills a fifth of the screen height (the showcase near-block shot was 86 m).
const SIZE_MIN := 3.0 * TILE
## 160 tiles: the whole 128-tile map with margin.
const SIZE_MAX := 160.0 * TILE
const SIZE_DEFAULT := 40.0 * TILE
const ZOOM_FACTOR := 1.15
## Metres per second per metre of view size, so on-screen pan speed stays constant.
const PAN_PER_SIZE := 0.9
const EDGE_MARGIN_PX := 14.0
const NO_TILE := Vector2i(-1, -1)
## ground_point() result when the ray misses the ground plane (test with is_finite()).
const NO_GROUND := Vector3(INF, INF, INF)

## Pitch is the view direction's angle below the horizon, in degrees.
const PITCH_DEFAULT := 65.0
const PITCH_MIN := 30.0
const PITCH_MIN_PERSPECTIVE := 25.0
const PITCH_MAX := 70.0
const YAW_DEFAULT := 0.0
## Vertical field of view of the perspective street view.
const FOV_DEG := 50.0
## A press that moves more than this (viewport pixels) before release is a drag.
const DRAG_PX := 4.0
const TILT_DEG_PER_PX := 0.25
const ORBIT_DEG_PER_PX := 0.3
const TILT_DEG_PER_SEC := 60.0
const ORBIT_DEG_PER_SEC := 90.0

## Orthographic depth kept between the near plane and the nearest scene point.
const NEAR_PAD := 60.0
## Tallest live building (C2 tower, crown and antenna) in metres.
const SCENE_HEIGHT := 140.0
## Depth kept past the farthest visible ground (the terrain quad sits at -0.06 m).
const FAR_PAD := 40.0
## Perspective near plane as a fraction of the focus distance, and its bounds.
const PERSPECTIVE_NEAR_FRACTION := 0.01
const PERSPECTIVE_NEAR_MIN := 0.5
const PERSPECTIVE_NEAR_MAX := 100.0
## Perspective far plane cap: the terrain quad's far corner is under 10 km from any map point.
const PERSPECTIVE_FAR_MAX := 12000.0
## Perspective shadow reach relative to the focus distance (beyond it the sun shadow fades).
const SHADOW_REACH_PER_DISTANCE := 6.0
## Zoom anchors farther than this many map extents outside the map are ignored (perspective
## rays near the horizon land kilometres away).
const ANCHOR_MARGIN_EXTENTS := 1.0

## Point on the ground plane the camera looks at (metres).
var target: Vector3 = Vector3(Cfg.map_extent() * 0.5, 0.0, Cfg.map_extent() * 0.5)
var pitch_deg: float = PITCH_DEFAULT
var yaw_deg: float = YAW_DEFAULT
var perspective: bool = false
var keyboard_pan_enabled := true
var edge_pan_enabled := true
## Panning needs window focus so an unfocused window never drifts. The dev input
## script turns this off because an unattended run cannot take focus on macOS.
var require_focus := true
## Tracked from the window's mouse_entered / mouse_exited; the dev input script sets
## it because a synthetic pointer is inside the window by construction.
var mouse_inside := false

var _block := Vector2i(-1, -1)
## Last pointer position from mouse-motion events (real or synthetic); the edge pan
## reads this rather than the OS cursor so it sees every event the game saw.
var _pointer := Vector2(-1.0, -1.0)
var _right := DragGesture.new()
var _middle := DragGesture.new()


## Press / move / release bookkeeping for one mouse button: nothing happens until the pointer
## has moved more than CameraRig.DRAG_PX from the press point; a release before that is a click.
class DragGesture:
	var down := false
	var dragging := false
	var origin := Vector2.ZERO

	func press(at: Vector2) -> void:
		down = true
		dragging = false
		origin = at

	## True when the button was down and never dragged: a click.
	func release() -> bool:
		var click := down and not dragging
		down = false
		dragging = false
		return click

	## Pointer motion to apply: zero until the threshold is crossed, the whole approach on the
	## frame it is crossed (so no motion is lost), the event's relative motion afterwards.
	func move(at: Vector2, relative: Vector2) -> Vector2:
		if not down:
			return Vector2.ZERO
		if dragging:
			return relative
		if not CameraRig.is_drag(origin, at):
			return Vector2.ZERO
		dragging = true
		return at - origin


func _ready() -> void:
	projection = Camera3D.PROJECTION_ORTHOGONAL
	current = true
	size = SIZE_DEFAULT
	var window := get_window()
	window.mouse_entered.connect(func() -> void: mouse_inside = true)
	window.mouse_exited.connect(func() -> void: mouse_inside = false)
	_apply()


func focus_tile(x: int, y: int) -> void:
	target = Cfg.to_world(Vector2i(x, y))
	_apply()


## Centers on an 8×8 block.
func focus_block(block_x: int, block_y: int) -> void:
	var half := SliceConstants.INTEREST_BLOCK * 0.5
	target = Vector3(
		(block_x * SliceConstants.INTEREST_BLOCK + half) * TILE, 0.0, (block_y * SliceConstants.INTEREST_BLOCK + half) * TILE
	)
	_apply()


## View size in metres (the vertical extent of the view at the target), both projections.
func set_ortho_size(value: float) -> void:
	size = clampf(value, SIZE_MIN, SIZE_MAX)
	_apply()


## Positive steps zoom in, about the target.
func zoom_steps(steps: int) -> void:
	if steps == 0:
		return
	set_ortho_size(size / pow(ZOOM_FACTOR, steps))


## Zoom about the ground point under a viewport position: that point stays under the pointer.
## Translating the camera does not change any pixel's ray direction (in either projection), so
## one correction by the anchor's drift is exact; the map clamp of the target can still move it.
## Falls back to zooming about the target when the ray misses the ground or lands far outside.
func zoom_at(screen: Vector2, steps: int) -> void:
	if steps == 0:
		return
	var anchor := ground_point(screen)
	zoom_steps(steps)
	if not anchor_usable(anchor):
		return
	var after := ground_point(screen)
	if not after.is_finite():
		return
	target += anchor - after
	_apply()


func set_pitch(degrees: float) -> void:
	pitch_deg = clamp_pitch(degrees, perspective)
	_apply()


func add_pitch(degrees: float) -> void:
	set_pitch(pitch_deg + degrees)


func set_yaw(degrees: float) -> void:
	yaw_deg = wrapf(degrees, -180.0, 180.0)
	_apply()


func add_yaw(degrees: float) -> void:
	set_yaw(yaw_deg + degrees)


## Default pitch, looking north. Size and projection are kept.
func reset_view() -> void:
	pitch_deg = PITCH_DEFAULT
	yaw_deg = YAW_DEFAULT
	_apply()


## Perspective street view on, orthographic off. The pitch is re-clamped to the mode's floor.
func set_perspective_mode(on: bool) -> void:
	if perspective == on:
		return
	perspective = on
	_apply()


func toggle_perspective() -> void:
	set_perspective_mode(not perspective)


## Camera distance from the target along the view direction.
func focus_distance() -> float:
	if perspective:
		return perspective_distance(size, FOV_DEG)
	var pitch := deg_to_rad(pitch_deg)
	# the far-edge ground is half the ground depth span deeper than the target; a tower below the
	# near edge whose top still shows is up to SCENE_HEIGHT / sin(pitch) shallower than that edge
	return size * depth_per_size(pitch) + SCENE_HEIGHT / sin(pitch) + NEAR_PAD


## Depth (along the view axis) of the nearest visible ground: the near screen edge.
func shadow_near() -> float:
	var pitch := deg_to_rad(pitch_deg)
	var dist := focus_distance()
	if perspective:
		return ground_depth(dist, pitch, -tan(deg_to_rad(FOV_DEG) * 0.5))
	return dist - size * depth_per_size(pitch)


## Depth up to which the sun shadow should reach: the whole tight range in orthographic
## projection, a multiple of the focus distance in perspective (the far plane may be at the
## horizon cap there, and a 4096 atlas spread over 12 km would blur every shadow).
func shadow_distance() -> float:
	if perspective:
		return minf(far, focus_distance() * SHADOW_REACH_PER_DISTANCE)
	return far


## Last pointer position seen by this camera (viewport coordinates).
func pointer() -> Vector2:
	return _pointer


## Tile under the look-at target.
func target_tile() -> Vector2i:
	return Vector2i(
		clampi(floori(target.x / TILE), 0, SliceConstants.MAP_SIZE - 1),
		clampi(floori(target.z / TILE), 0, SliceConstants.MAP_SIZE - 1)
	)


func current_block() -> Vector2i:
	var tile := target_tile()
	var block := InterestId.from_tile(tile.x, tile.y)
	return Vector2i(block.block_x, block.block_y)


## Ground-plane point under a viewport position through the actual projection, NO_GROUND
## when the ray does not descend to y = 0 (perspective rays at or above the horizon).
func ground_point(screen: Vector2) -> Vector3:
	return hit_ground(project_ray_origin(screen), project_ray_normal(screen))


## Tile under a viewport position, or NO_TILE when the ray misses the map.
func pick_tile(screen: Vector2) -> Vector2i:
	var hit := ground_point(screen)
	if not hit.is_finite():
		return NO_TILE
	var cell := Cfg.to_tile(hit)
	if not SliceConstants.in_map(cell.x, cell.y):
		return NO_TILE
	return cell


## Viewport position of a tile center; the dev input script aims synthetic clicks with it.
func tile_to_screen(cell: Vector2i) -> Vector2:
	return unproject_position(Cfg.to_world(cell))


## Ray / ground-plane (y = 0) intersection; NO_GROUND when the ray does not point down.
static func hit_ground(origin: Vector3, normal: Vector3) -> Vector3:
	if normal.y >= -1e-6:
		return NO_GROUND
	var t := -origin.y / normal.y
	if t < 0.0:
		return NO_GROUND
	return origin + normal * t


## A ground hit the zoom may anchor on: finite and within ANCHOR_MARGIN_EXTENTS of the map.
static func anchor_usable(hit: Vector3) -> bool:
	if not hit.is_finite():
		return false
	var extent := Cfg.map_extent()
	var margin := extent * ANCHOR_MARGIN_EXTENTS
	return hit.x > -margin and hit.x < extent + margin and hit.z > -margin and hit.z < extent + margin


## Half the ground depth span per metre of view size at a pitch (radians): cos / (2 sin).
## The screen height s covers s / sin(pitch) of ground; its depth along the view is s cot(pitch).
static func depth_per_size(pitch: float) -> float:
	return cos(pitch) / (2.0 * sin(pitch))


## Focus distance that makes a perspective view of `fov_deg` as tall as `view_size` at the target.
static func perspective_distance(view_size: float, fov_deg: float) -> float:
	return 0.5 * view_size / tan(deg_to_rad(fov_deg) * 0.5)


## Inverse of perspective_distance.
static func size_for_distance(distance: float, fov_deg: float) -> float:
	return 2.0 * distance * tan(deg_to_rad(fov_deg) * 0.5)


## Depth along the view axis at which the ray through screen height `b` (tan of its angle from
## the axis, positive upward) meets the ground, for a camera `dist` from its ground target at
## `pitch` (radians). INF when that ray does not descend. The depth is the same for the whole
## screen row, corners included, which is why the far plane is a plane.
static func ground_depth(dist: float, pitch: float, b: float) -> float:
	var descent := sin(pitch) - b * cos(pitch)
	if descent <= 1e-3:
		return INF
	return dist * sin(pitch) / descent


## Perspective far plane: the farthest visible ground (top screen edge) plus FAR_PAD, capped.
static func perspective_far(dist: float, p_pitch_deg: float) -> float:
	var depth := ground_depth(dist, deg_to_rad(p_pitch_deg), tan(deg_to_rad(FOV_DEG) * 0.5))
	if not is_finite(depth):
		return PERSPECTIVE_FAR_MAX
	return minf(depth + FAR_PAD, PERSPECTIVE_FAR_MAX)


static func clamp_pitch(degrees: float, in_perspective: bool) -> float:
	return clampf(degrees, PITCH_MIN_PERSPECTIVE if in_perspective else PITCH_MIN, PITCH_MAX)


## Click / drag rule shared with PlayInput's right-click cancel.
static func is_drag(press: Vector2, now: Vector2) -> bool:
	return press.distance_to(now) > DRAG_PX


## Screen-space pan direction (x right, y down, as mouse coordinates) to a ground offset for a
## camera at `p_yaw_deg`: at yaw 0 "up" moves north (-Z) and "right" moves east (+X).
static func pan_on_ground(dir: Vector2, p_yaw_deg: float) -> Vector3:
	var yaw := deg_to_rad(p_yaw_deg)
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	return right * dir.x - forward * dir.y


## Mouse drags are read in _input so they also work when the press lands on a HUD panel;
## nothing is consumed, PlayInput's hover and PlayInput's own right-click rule still see them.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_pointer = event.position
		var tilt := _right.move(event.position, event.relative)
		if tilt != Vector2.ZERO:
			set_pitch(pitch_deg + tilt.y * TILT_DEG_PER_PX)
		var orbit := _middle.move(event.position, event.relative)
		if orbit != Vector2.ZERO:
			set_yaw(yaw_deg + orbit.x * ORBIT_DEG_PER_PX)
	elif event is InputEventMouseButton:
		var gesture: DragGesture = null
		if event.button_index == MOUSE_BUTTON_RIGHT:
			gesture = _right
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			gesture = _middle
		if gesture == null:
			return
		if event.pressed:
			gesture.press(event.position)
		else:
			gesture.release()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_at(event.position, 1)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_at(event.position, -1)
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			reset_view()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_V:
			toggle_perspective()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	var focused := get_window().has_focus() or not require_focus
	if keyboard_pan_enabled and focused:
		if Input.is_physical_key_pressed(KEY_W):
			dir.y -= 1.0
		if Input.is_physical_key_pressed(KEY_S):
			dir.y += 1.0
		if Input.is_physical_key_pressed(KEY_A):
			dir.x -= 1.0
		if Input.is_physical_key_pressed(KEY_D):
			dir.x += 1.0
		if Input.is_physical_key_pressed(KEY_Q):
			pitch_deg -= TILT_DEG_PER_SEC * delta
		if Input.is_physical_key_pressed(KEY_E):
			pitch_deg += TILT_DEG_PER_SEC * delta
		if Input.is_physical_key_pressed(KEY_LEFT):
			yaw_deg = wrapf(yaw_deg - ORBIT_DEG_PER_SEC * delta, -180.0, 180.0)
		if Input.is_physical_key_pressed(KEY_RIGHT):
			yaw_deg = wrapf(yaw_deg + ORBIT_DEG_PER_SEC * delta, -180.0, 180.0)
	if edge_pan_enabled and focused and mouse_inside:
		var rect := get_viewport().get_visible_rect()
		if rect.has_point(_pointer):
			if _pointer.x < rect.position.x + EDGE_MARGIN_PX:
				dir.x -= 1.0
			elif _pointer.x > rect.end.x - EDGE_MARGIN_PX:
				dir.x += 1.0
			if _pointer.y < rect.position.y + EDGE_MARGIN_PX:
				dir.y -= 1.0
			elif _pointer.y > rect.end.y - EDGE_MARGIN_PX:
				dir.y += 1.0
	if dir != Vector2.ZERO:
		target += pan_on_ground(dir.normalized() * PAN_PER_SIZE * size * delta, yaw_deg)
	_apply()


func _apply() -> void:
	var limit := Cfg.map_extent()
	target.x = clampf(target.x, 0.0, limit)
	target.z = clampf(target.z, 0.0, limit)
	target.y = 0.0
	pitch_deg = clamp_pitch(pitch_deg, perspective)
	var pitch := deg_to_rad(pitch_deg)
	var dist := focus_distance()
	if perspective:
		projection = Camera3D.PROJECTION_PERSPECTIVE
		fov = FOV_DEG
		near = clampf(dist * PERSPECTIVE_NEAR_FRACTION, PERSPECTIVE_NEAR_MIN, PERSPECTIVE_NEAR_MAX)
		far = perspective_far(dist, pitch_deg)
	else:
		projection = Camera3D.PROJECTION_ORTHOGONAL
		near = NEAR_PAD
		far = dist + size * depth_per_size(pitch) + FAR_PAD
	var offset := Vector3(0.0, dist * sin(pitch), dist * cos(pitch)).rotated(Vector3.UP, deg_to_rad(yaw_deg))
	position = target + offset
	look_at(target, Vector3.UP)
	var block := current_block()
	if block != _block:
		_block = block
		block_changed.emit(block.x, block.y)

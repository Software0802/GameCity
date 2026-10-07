class_name CameraRig
extends Camera3D

## Orthographic micro-oblique camera (25° off vertical, art brief). World units are metres,
## LiveCfg.P (30 m) per game tile; every public entry point speaks tiles and converts.
## WASD and screen edges pan, the wheel zooms (ortho size SIZE_MIN..SIZE_MAX in metres), and
## the look-at target is clamped to the map. block_changed fires when the target's 8×8 block
## changes so the owner can call GameNet.set_camera_local.
##
## The camera distance scales with the ortho size so the depth range [near, far] hugs the
## visible ground and the tallest buildings: directional shadows and SSAO work in that range
## and the clip planes never cut a tower at the near screen edge.

signal block_changed(block_x: int, block_y: int)

const Cfg := preload("res://client/assets/techart/live/scripts/live_cfg.gd")

const PITCH_DEG := 65.0
const TILE := Cfg.P
## 3 tiles: one lot fills a fifth of the screen height (the showcase near-block shot was 86 m).
const SIZE_MIN := 3.0 * TILE
## 160 tiles: the whole 128-tile map with margin.
const SIZE_MAX := 160.0 * TILE
const SIZE_DEFAULT := 40.0 * TILE
const ZOOM_FACTOR := 1.15
## Metres per second per metre of ortho size, so on-screen pan speed stays constant.
const PAN_PER_SIZE := 0.9
const EDGE_MARGIN_PX := 14.0
const NO_TILE := Vector2i(-1, -1)
## Depth kept between the near plane and the nearest scene point.
const NEAR_PAD := 60.0
## Tallest live building (C2 tower, crown and antenna) in metres.
const SCENE_HEIGHT := 140.0
## Ground depth span per metre of ortho size at PITCH_DEG: cos(65°) / (2 sin(65°)).
const DEPTH_PER_SIZE := 0.24

## Point on the ground plane the camera looks at (metres).
var target: Vector3 = Vector3(Cfg.map_extent() * 0.5, 0.0, Cfg.map_extent() * 0.5)
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


## Ortho size in metres (the vertical extent of the view).
func set_ortho_size(value: float) -> void:
	size = clampf(value, SIZE_MIN, SIZE_MAX)
	_apply()


## Positive steps zoom in.
func zoom_steps(steps: int) -> void:
	if steps == 0:
		return
	set_ortho_size(size / pow(ZOOM_FACTOR, steps))


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


## Tile under a viewport position, or NO_TILE when the ray misses the map.
func pick_tile(screen: Vector2) -> Vector2i:
	var origin := project_ray_origin(screen)
	var normal := project_ray_normal(screen)
	if absf(normal.y) < 1e-6:
		return NO_TILE
	var t := -origin.y / normal.y
	if t < 0.0:
		return NO_TILE
	var hit := origin + normal * t
	var cell := Cfg.to_tile(hit)
	if not SliceConstants.in_map(cell.x, cell.y):
		return NO_TILE
	return cell


## Viewport position of a tile center; the dev input script aims synthetic clicks with it.
func tile_to_screen(cell: Vector2i) -> Vector2:
	return unproject_position(Cfg.to_world(cell))


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_pointer = event.position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_steps(1)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_steps(-1)
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
		dir = dir.normalized() * PAN_PER_SIZE * size * delta
		target.x += dir.x
		target.z += dir.y
	_apply()


func _apply() -> void:
	var limit := Cfg.map_extent()
	target.x = clampf(target.x, 0.0, limit)
	target.z = clampf(target.z, 0.0, limit)
	target.y = 0.0
	var pitch := deg_to_rad(PITCH_DEG)
	# nearest scene point: the far-edge ground is DEPTH_PER_SIZE * size deeper, a tower at the
	# near edge is up to SCENE_HEIGHT * sin(pitch) shallower
	var reach := size * DEPTH_PER_SIZE + SCENE_HEIGHT
	var dist := reach + NEAR_PAD
	rotation_degrees = Vector3(-PITCH_DEG, 0.0, 0.0)
	position = target + Vector3(0.0, dist * sin(pitch), dist * cos(pitch))
	near = NEAR_PAD
	far = dist + size * DEPTH_PER_SIZE + 40.0
	var block := current_block()
	if block != _block:
		_block = block
		block_changed.emit(block.x, block.y)

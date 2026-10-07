class_name CameraRig
extends Camera3D

## Orthographic micro-oblique camera (25° off vertical, art brief). WASD and screen
## edges pan, the wheel zooms (ortho size SIZE_MIN..SIZE_MAX), and the look-at target is
## clamped to the map. block_changed fires when the target's 8×8 block changes so the
## owner can call GameNet.set_camera_local.

signal block_changed(block_x: int, block_y: int)

const PITCH_DEG := 65.0
## Distance along the view ray; only clipping depends on it for an orthographic camera.
const DISTANCE := 150.0
const SIZE_MIN := 16.0
const SIZE_MAX := 160.0
const SIZE_DEFAULT := 40.0
const ZOOM_FACTOR := 1.15
## Tiles per second per unit of ortho size, so on-screen pan speed stays constant.
const PAN_PER_SIZE := 0.9
const EDGE_MARGIN_PX := 14.0
const NO_TILE := Vector2i(-1, -1)

## Point on the ground plane the camera looks at.
var target: Vector3 = Vector3(SliceConstants.MAP_SIZE * 0.5, 0.0, SliceConstants.MAP_SIZE * 0.5)
var keyboard_pan_enabled := true
var edge_pan_enabled := true

var _mouse_inside := false
var _block := Vector2i(-1, -1)


func _ready() -> void:
	projection = Camera3D.PROJECTION_ORTHOGONAL
	current = true
	near = 0.05
	far = DISTANCE * 3.0
	size = SIZE_DEFAULT
	var window := get_window()
	window.mouse_entered.connect(func() -> void: _mouse_inside = true)
	window.mouse_exited.connect(func() -> void: _mouse_inside = false)
	_apply()


func focus_tile(x: int, y: int) -> void:
	target = Vector3(x + 0.5, 0.0, y + 0.5)
	_apply()


## Centers on an 8×8 block.
func focus_block(block_x: int, block_y: int) -> void:
	var half := SliceConstants.INTEREST_BLOCK * 0.5
	target = Vector3(
		block_x * SliceConstants.INTEREST_BLOCK + half, 0.0, block_y * SliceConstants.INTEREST_BLOCK + half
	)
	_apply()


func set_ortho_size(value: float) -> void:
	size = clampf(value, SIZE_MIN, SIZE_MAX)


## Positive steps zoom in.
func zoom_steps(steps: int) -> void:
	if steps == 0:
		return
	set_ortho_size(size / pow(ZOOM_FACTOR, steps))


func current_block() -> Vector2i:
	var tile := Vector2i(
		clampi(floori(target.x), 0, SliceConstants.MAP_SIZE - 1),
		clampi(floori(target.z), 0, SliceConstants.MAP_SIZE - 1)
	)
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
	var cell := Vector2i(floori(hit.x), floori(hit.z))
	if not SliceConstants.in_map(cell.x, cell.y):
		return NO_TILE
	return cell


## Viewport position of a tile center; the dev input script aims synthetic clicks with it.
func tile_to_screen(cell: Vector2i) -> Vector2:
	return unproject_position(Vector3(cell.x + 0.5, 0.0, cell.y + 0.5))


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
	var window := get_window()
	var focused := window.has_focus()
	if keyboard_pan_enabled and focused:
		if Input.is_physical_key_pressed(KEY_W):
			dir.y -= 1.0
		if Input.is_physical_key_pressed(KEY_S):
			dir.y += 1.0
		if Input.is_physical_key_pressed(KEY_A):
			dir.x -= 1.0
		if Input.is_physical_key_pressed(KEY_D):
			dir.x += 1.0
	if edge_pan_enabled and focused and _mouse_inside:
		var mouse := get_viewport().get_mouse_position()
		var rect := get_viewport().get_visible_rect()
		if rect.has_point(mouse):
			if mouse.x < rect.position.x + EDGE_MARGIN_PX:
				dir.x -= 1.0
			elif mouse.x > rect.end.x - EDGE_MARGIN_PX:
				dir.x += 1.0
			if mouse.y < rect.position.y + EDGE_MARGIN_PX:
				dir.y -= 1.0
			elif mouse.y > rect.end.y - EDGE_MARGIN_PX:
				dir.y += 1.0
	if dir != Vector2.ZERO:
		dir = dir.normalized() * PAN_PER_SIZE * size * delta
		target.x += dir.x
		target.z += dir.y
	_apply()


func _apply() -> void:
	var limit := float(SliceConstants.MAP_SIZE)
	target.x = clampf(target.x, 0.0, limit)
	target.z = clampf(target.z, 0.0, limit)
	target.y = 0.0
	var pitch := deg_to_rad(PITCH_DEG)
	rotation_degrees = Vector3(-PITCH_DEG, 0.0, 0.0)
	position = target + Vector3(0.0, DISTANCE * sin(pitch), DISTANCE * cos(pitch))
	var block := current_block()
	if block != _block:
		_block = block
		block_changed.emit(block.x, block.y)

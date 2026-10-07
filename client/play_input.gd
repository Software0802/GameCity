class_name PlayInput
extends Node

## Mouse → camera ray → ground plane → tile → GameCommand. The active Toolbar tool
## decides the command; the left button casts, holding it paints zones tile by tile
## and lays roads edge by edge, the right button clears the tool. Events that land
## on HUD controls never arrive here (the GUI consumes them first).
##
## A fast drag can skip tiles; the gap is filled along a Manhattan path (x first,
## then y) so every road step stays orthogonal and every zone tile is visited once.

signal hover_changed(cell: Vector2i)

const TOOL_KEYS := {
	KEY_1: Toolbar.Tool.CLAIM,
	KEY_2: Toolbar.Tool.ZONE_R,
	KEY_3: Toolbar.Tool.ZONE_C,
	KEY_4: Toolbar.Tool.ZONE_I,
	KEY_5: Toolbar.Tool.ZONE_CLEAR,
	KEY_6: Toolbar.Tool.ROAD,
	KEY_7: Toolbar.Tool.POWER,
	KEY_8: Toolbar.Tool.DEMOLISH,
}

var session: ClientSession
var camera: CameraRig
var toolbar: Toolbar
var world: WorldView

var hover: Vector2i = CameraRig.NO_TILE
var dragging: bool = false

var _drag_last: Vector2i = CameraRig.NO_TILE
var _drag_sent: Dictionary = {}


func setup(p_session: ClientSession, p_camera: CameraRig, p_toolbar: Toolbar, p_world: WorldView) -> void:
	session = p_session
	camera = p_camera
	toolbar = p_toolbar
	world = p_world
	toolbar.tool_changed.connect(func(_tool: int) -> void: _refresh_hover_color())


## Right button cancels the tool wherever it lands, including over the HUD, so it
## is read before the GUI gets the event; it is not consumed.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_end_drag()
		toolbar.set_tool(Toolbar.Tool.NONE)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover(event.position)
		if dragging:
			if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
				_drag_to(hover)
			else:
				_end_drag()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin(event.position)
			else:
				_end_drag()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_end_drag()
			toolbar.set_tool(Toolbar.Tool.NONE)
		elif TOOL_KEYS.has(event.keycode):
			toolbar.toggle_tool(TOOL_KEYS[event.keycode])


func _begin(screen: Vector2) -> void:
	_update_hover(screen)
	if hover == CameraRig.NO_TILE or toolbar.tool == Toolbar.Tool.NONE or not session.can_act():
		return
	dragging = true
	_drag_sent.clear()
	_drag_last = hover
	if toolbar.tool != Toolbar.Tool.ROAD:
		_cast(hover)


func _end_drag() -> void:
	dragging = false
	_drag_last = CameraRig.NO_TILE
	_drag_sent.clear()


func _drag_to(cell: Vector2i) -> void:
	if cell == CameraRig.NO_TILE or cell == _drag_last:
		return
	if not session.can_act():
		_end_drag()
		return
	match toolbar.tool:
		Toolbar.Tool.ROAD:
			var previous := _drag_last
			for step in manhattan_path(_drag_last, cell):
				_send_edge(previous, step)
				previous = step
		Toolbar.Tool.ZONE_R, Toolbar.Tool.ZONE_C, Toolbar.Tool.ZONE_I, Toolbar.Tool.ZONE_CLEAR:
			for step in manhattan_path(_drag_last, cell):
				_cast(step)
		_:
			pass
	_drag_last = cell


## Tiles from `from` (exclusive) to `to` (inclusive), x first then y.
static func manhattan_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var cursor := from
	while cursor.x != to.x:
		cursor.x += signi(to.x - cursor.x)
		path.append(cursor)
	while cursor.y != to.y:
		cursor.y += signi(to.y - cursor.y)
		path.append(cursor)
	return path


func _cast(cell: Vector2i) -> void:
	if not SliceConstants.in_map(cell.x, cell.y):
		return
	var key := "t%d" % SliceConstants.tile_id(cell.x, cell.y)
	if _drag_sent.has(key):
		return
	_drag_sent[key] = true
	match toolbar.tool:
		Toolbar.Tool.CLAIM:
			session.send_command(GameCommand.claim_tile(cell.x, cell.y))
		Toolbar.Tool.ZONE_R:
			session.send_command(GameCommand.set_zone(cell.x, cell.y, SliceConstants.Zone.R))
		Toolbar.Tool.ZONE_C:
			session.send_command(GameCommand.set_zone(cell.x, cell.y, SliceConstants.Zone.C))
		Toolbar.Tool.ZONE_I:
			session.send_command(GameCommand.set_zone(cell.x, cell.y, SliceConstants.Zone.I))
		Toolbar.Tool.ZONE_CLEAR:
			session.send_command(GameCommand.set_zone(cell.x, cell.y, SliceConstants.Zone.NONE))
		Toolbar.Tool.POWER:
			session.send_command(GameCommand.place_power(cell.x, cell.y))
		Toolbar.Tool.DEMOLISH:
			session.send_command(GameCommand.demolish_own(cell.x, cell.y))
		_:
			pass


func _send_edge(a: Vector2i, b: Vector2i) -> void:
	if not EdgeDelta.is_orthogonal(a, b):
		return
	if not SliceConstants.in_map(a.x, a.y) or not SliceConstants.in_map(b.x, b.y):
		return
	var key := "e" + WorldState.edge_key(a, b)
	if _drag_sent.has(key):
		return
	_drag_sent[key] = true
	session.send_command(GameCommand.add_edge(a, b))


func _update_hover(screen: Vector2) -> void:
	var next := camera.pick_tile(screen)
	if next == hover:
		return
	hover = next
	_refresh_hover_color()
	hover_changed.emit(hover)


func _refresh_hover_color() -> void:
	var color := Palette.HUD_TEXT
	if toolbar.tool != Toolbar.Tool.NONE:
		color = Palette.WARN
	world.set_hover(hover, hover != CameraRig.NO_TILE, color)

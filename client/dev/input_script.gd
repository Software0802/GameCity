class_name InputScript
extends Node

## Dev-only. Replays a text script as synthetic input through Input.parse_input_event
## so the production picking, toolbar, and slider code paths run exactly as with a
## real mouse. One line per frame; multi-step lines (drag) spread over frames.
## Started with --input-script <path>; `finished` turns true after the last line.
##
##   wait <frames>
##   focus <x> <y>              camera.focus_tile (dev shortcut)
##   zoom <ortho_size>          camera.set_ortho_size (dev shortcut)
##   tool <name>                click the toolbar button: claim zone_r zone_c zone_i zone_clear road power demolish
##   hover <x> <y>              move the pointer over tile x,y
##   click <x> <y>              left click on tile x,y
##   rclick                     right click at the current pointer
##   drag <x0> <y0> <x1> <y1>   press on tile0, move through the Manhattan path, release on tile1
##   slider <rate>              press and release on the tax slider at rate
##   key <name> <frames>        hold a key (W A S D ...) for frames
##   wheel <steps>              wheel up (steps > 0) or down at the pointer
##   print <text>
## Lines starting with # are comments.

var camera: CameraRig
var toolbar: Toolbar
var finished: bool = false

var _lines: PackedStringArray = []
var _index: int = 0
var _wait: int = 0
var _pointer: Vector2 = Vector2(640, 360)
var _queue: Array[Callable] = []


func setup(p_camera: CameraRig, p_toolbar: Toolbar) -> void:
	camera = p_camera
	toolbar = p_toolbar


func load_file(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("input script not found: %s" % path)
		finished = true
		return false
	_lines = file.get_as_text().split("\n")
	return true


func _process(_delta: float) -> void:
	if finished:
		return
	if _wait > 0:
		_wait -= 1
		return
	if not _queue.is_empty():
		var step: Callable = _queue.pop_front()
		step.call()
		return
	if _index >= _lines.size():
		finished = true
		print("INPUT_SCRIPT_DONE")
		return
	var line := _lines[_index].strip_edges()
	_index += 1
	if line.is_empty() or line.begins_with("#"):
		return
	_run(line)


func _run(line: String) -> void:
	var parts := line.split(" ", false)
	var op := parts[0]
	match op:
		"wait":
			_wait = int(parts[1])
		"focus":
			camera.focus_tile(int(parts[1]), int(parts[2]))
		"zoom":
			camera.set_ortho_size(float(parts[1]))
		"tool":
			var tool := Toolbar.tool_from_name(parts[1])
			var button := toolbar.button_for(tool)
			if button == null:
				push_error("input script: unknown tool %s" % parts[1])
				return
			_move(button.get_global_rect().get_center())
			_queue.append(func() -> void: _button(MOUSE_BUTTON_LEFT, true))
			_queue.append(func() -> void: _button(MOUSE_BUTTON_LEFT, false))
		"hover":
			_move(camera.tile_to_screen(Vector2i(int(parts[1]), int(parts[2]))))
		"click":
			var cell := Vector2i(int(parts[1]), int(parts[2]))
			_move(camera.tile_to_screen(cell))
			_queue.append(func() -> void: _button(MOUSE_BUTTON_LEFT, true))
			_queue.append(func() -> void: _button(MOUSE_BUTTON_LEFT, false))
		"rclick":
			_button(MOUSE_BUTTON_RIGHT, true)
			_queue.append(func() -> void: _button(MOUSE_BUTTON_RIGHT, false))
		"drag":
			var from := Vector2i(int(parts[1]), int(parts[2]))
			var to := Vector2i(int(parts[3]), int(parts[4]))
			_move(camera.tile_to_screen(from))
			_queue.append(func() -> void: _button(MOUSE_BUTTON_LEFT, true))
			for step in PlayInput.manhattan_path(from, to):
				var target := step
				_queue.append(func() -> void: _move(camera.tile_to_screen(target)))
			_queue.append(func() -> void: _button(MOUSE_BUTTON_LEFT, false))
		"slider":
			_move(toolbar.tax_slider_point(float(parts[1])))
			_queue.append(func() -> void: _button(MOUSE_BUTTON_LEFT, true))
			_queue.append(func() -> void: _button(MOUSE_BUTTON_LEFT, false))
		"key":
			var keycode := OS.find_keycode_from_string(parts[1])
			var frames := int(parts[2])
			_key(keycode, true)
			_queue.append(func() -> void: _wait = frames)
			_queue.append(func() -> void: _key(keycode, false))
		"wheel":
			var steps := int(parts[1])
			var index := MOUSE_BUTTON_WHEEL_UP if steps > 0 else MOUSE_BUTTON_WHEEL_DOWN
			for i in absi(steps):
				_queue.append(func() -> void: _button(index, true))
				_queue.append(func() -> void: _button(index, false))
		"print":
			print("INPUT_SCRIPT " + " ".join(parts.slice(1)))
		_:
			push_error("input script: unknown op %s" % op)


func _move(to: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = to
	event.global_position = to
	event.relative = to - _pointer
	event.button_mask = Input.get_mouse_button_mask()
	_pointer = to
	Input.parse_input_event(event)


func _button(index: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.pressed = pressed
	event.position = _pointer
	event.global_position = _pointer
	Input.parse_input_event(event)


func _key(keycode: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)

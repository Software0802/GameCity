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
##   edge <left|right|up|down> <frames>   park the pointer in the edge-pan margin for frames
##   wheel <steps>              wheel up (steps > 0) or down at the pointer
##   print <text>
##   dump                       print camera target, ortho size, tracked pointer, visible rect, tool
##   guide                      print the opening guide's progress, the alert feed and the hover line
## Lines starting with # are comments.

const TOOL_TRIES := 3

var camera: CameraRig
var toolbar: Toolbar
## Optional; the `guide` op reads them.
var hud: Hud = null
var session: ClientSession = null
var finished: bool = false

var _lines: PackedStringArray = []
var _index: int = 0
var _wait: int = 0
var _pointer: Vector2 = Vector2(640, 360)
var _queue: Array[Callable] = []


func setup(p_camera: CameraRig, p_toolbar: Toolbar, p_hud: Hud = null, p_session: ClientSession = null) -> void:
	camera = p_camera
	toolbar = p_toolbar
	hud = p_hud
	session = p_session


## Camera panning is gated on window focus, which an unattended run cannot obtain on
## macOS (the launching app keeps it); the gate is lifted for the scripted run and the
## synthetic pointer counts as inside the window. Everything else is the production path.
func _ready() -> void:
	camera.require_focus = false
	camera.mouse_inside = true


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
			_select_tool(tool, button, TOOL_TRIES)
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
		"edge":
			# Park the pointer in the screen-edge margin for N frames, then return to the centre.
			var rect := get_viewport().get_visible_rect()
			var inset := CameraRig.EDGE_MARGIN_PX * 0.5
			var at := rect.get_center()
			match parts[1]:
				"left":
					at.x = rect.position.x + inset
				"right":
					at.x = rect.end.x - inset
				"up":
					at.y = rect.position.y + inset
				"down":
					at.y = rect.end.y - inset
			var frames := int(parts[2])
			_move(at)
			_queue.append(func() -> void: _wait = frames)
			_queue.append(func() -> void: _move(rect.get_center()))
		"wheel":
			var steps := int(parts[1])
			var index := MOUSE_BUTTON_WHEEL_UP if steps > 0 else MOUSE_BUTTON_WHEEL_DOWN
			for i in absi(steps):
				_queue.append(func() -> void: _button(index, true))
				_queue.append(func() -> void: _button(index, false))
		"print":
			print("INPUT_SCRIPT " + " ".join(parts.slice(1)))
		"dump":
			print("INPUT_SCRIPT dump target=%s size=%.2f pointer=%s rect=%s inside=%s tool=%s" % [
				camera.target, camera.size, camera.pointer(), get_viewport().get_visible_rect(),
				camera.mouse_inside, Toolbar.TOOL_NAMES[toolbar.tool]
			])
		"guide":
			_print_guide()
		_:
			push_error("input script: unknown op %s" % op)


## Machine-readable guide state for scripted runs (grep "INPUT_SCRIPT guide"). The guide is
## re-evaluated first so the line reflects the events applied up to this frame.
func _print_guide() -> void:
	var progress := -1
	var shown := false
	var complete := false
	if hud != null and hud.guide != null:
		if session != null:
			hud.guide.refresh(session, Time.get_ticks_msec())
		progress = hud.guide.progress
		shown = hud.guide.is_visible()
		complete = hud.guide.is_complete()
	var alerts: Array[String] = []
	if session != null:
		for alert in session.alerts:
			alerts.append(str(alert["text"]))
	var hover := ""
	if hud != null:
		hover = hud.hover_text()
	print("INPUT_SCRIPT guide progress=%d/%d shown=%s complete=%s alerts=%s hover=\"%s\"" % [
		progress, StartGuide.STEP_COUNT, shown, complete, JSON.stringify(alerts), hover
	])
	if hud != null:
		print("INPUT_SCRIPT " + hud.guide_panel_info())


## Clicks the toolbar button over three frames, then checks that the tool took. A real
## pointer event from the OS (the cursor sitting over the window as it opens) can land
## between the synthetic press and release and cancel the button, so a missed selection
## is retried up to TOOL_TRIES times rather than silently running the script without a tool.
func _select_tool(tool: int, button: Button, tries: int) -> void:
	_move(button.get_global_rect().get_center())
	_queue.append(func() -> void: _button(MOUSE_BUTTON_LEFT, true))
	_queue.append(func() -> void: _button(MOUSE_BUTTON_LEFT, false))
	_queue.append(func() -> void:
		if toolbar.tool == tool:
			return
		if tries <= 1:
			push_error("input script: tool %s did not take" % Toolbar.TOOL_NAMES[tool])
			return
		print("INPUT_SCRIPT retry tool %s" % Toolbar.TOOL_NAMES[tool])
		_select_tool(tool, button, tries - 1)
	)


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

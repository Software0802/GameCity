extends Node3D

## Client entry (res://client/main.tscn). Wires the session mirror, the transport
## and handshake, the camera, mouse picking, the toolbar, the HUD, and the per-block
## view. Rules stay on the server; this node only forwards intents.
##
##   godot --path . -- --join 127.0.0.1 --port 24567 --name alice
##   godot --path . -- --stub --screenshot /tmp/stub.png --input-script client/dev/scripts/stub_showcase.txt
##
##   --join <host> --port <p>     server (default 127.0.0.1:24567)
##   --name <n>                   display name; default: identity file, else player-xxxx
##   --identity <path>            identity file (default user://identity.cfg; --stub uses user://identity_stub.cfg)
##   --stub                       no network: client/dev/stub_server.gd feeds the session
##   --screenshot <path>          save the viewport N frames after MatchStart, then quit
##   --screenshot-frames <n>      N above (default 150)
##   --screenshot-seconds <s>     wall-clock delay after MatchStart instead of frames
##   --input-script <path>        replay synthetic input (client/dev/input_script.gd)

const SCREENSHOT_FRAMES_DEFAULT := 150
const STUB_IDENTITY_PATH := "user://identity_stub.cfg"

@onready var camera: CameraRig = $Camera
@onready var world: WorldView = $World
@onready var play_input: PlayInput = $Input
@onready var connection: ClientConnection = $Connection
@onready var toolbar: Toolbar = $Hud/Toolbar
@onready var hud: Hud = $Hud/Panels
@onready var ground: MeshInstance3D = $Ground

var session: ClientSession
var identity: ClientIdentity
var stub: StubServer = null
var input_script: InputScript = null

var _screenshot_path := ""
var _screenshot_frames := SCREENSHOT_FRAMES_DEFAULT
## Negative means "count frames instead".
var _screenshot_seconds := -1.0
var _frames_since_start := -1
var _seconds_since_start := 0.0
var _screenshot_taken := false
var _focused_once := false
var _camera_block := Vector2i(-1, -1)
var _camera_block_sent := Vector2i(-1, -1)
var _was_started := false


func _ready() -> void:
	get_viewport().msaa_3d = Viewport.MSAA_2X
	_size_ground()
	session = ClientSession.new()
	session.name = "Session"
	add_child(session)

	var stub_mode := LaunchArgs.has("--stub")
	var identity_path := LaunchArgs.value("--identity", STUB_IDENTITY_PATH if stub_mode else ClientIdentity.DEFAULT_PATH)
	identity = ClientIdentity.new(identity_path)
	identity.load()
	identity.ensure_name(LaunchArgs.value("--name", ""))
	identity.save()

	world.bind(session)
	hud.bind(session)
	play_input.setup(session, camera, toolbar, world)
	toolbar.tax_rate_committed.connect(_on_tax_rate_committed)
	session.updated.connect(_on_session_updated)
	camera.block_changed.connect(_on_camera_block_changed)
	play_input.hover_changed.connect(_on_hover_changed)
	connection.state_changed.connect(func(_state: int) -> void: _refresh_connection_text())

	var spawn := WorldState.spawn_block(SliceConstants.Owner.FACTION_A)
	camera.focus_block(spawn.block_x, spawn.block_y)

	_screenshot_path = LaunchArgs.value("--screenshot", "")
	_screenshot_frames = LaunchArgs.int_value("--screenshot-frames", SCREENSHOT_FRAMES_DEFAULT)
	var seconds_arg := LaunchArgs.value("--screenshot-seconds", "")
	if seconds_arg.is_valid_float():
		_screenshot_seconds = float(seconds_arg)
	var script_path := LaunchArgs.value("--input-script", "")
	if not script_path.is_empty():
		input_script = InputScript.new()
		input_script.name = "InputScript"
		input_script.setup(camera, toolbar)
		input_script.load_file(script_path)
		add_child(input_script)

	if stub_mode:
		stub = StubServer.new()
		stub.name = "StubServer"
		add_child(stub)
		stub.start(session, identity.name)
	else:
		connection.start(
			LaunchArgs.value("--join", ClientConnection.DEFAULT_HOST),
			LaunchArgs.int_value("--port", ClientConnection.DEFAULT_PORT),
			identity,
			session
		)
	_refresh_connection_text()
	_on_session_updated()


func _process(delta: float) -> void:
	_refresh_connection_text()
	if _frames_since_start >= 0:
		_frames_since_start += 1
		_seconds_since_start += delta
	if _screenshot_taken or _screenshot_path.is_empty() or _frames_since_start < 0:
		return
	var due := false
	if _screenshot_seconds >= 0.0:
		due = _seconds_since_start >= _screenshot_seconds
	else:
		due = _frames_since_start >= _screenshot_frames
	if due and (input_script == null or input_script.finished):
		_screenshot_taken = true
		_take_screenshot()


func _on_session_updated() -> void:
	var active := session.can_act()
	toolbar.set_enabled(active)
	toolbar.sync_tax_rate(session.view_tax_rate())
	if session.match_started and not _was_started:
		_frames_since_start = 0
		_camera_block_sent = Vector2i(-1, -1)
	_was_started = session.match_started
	if session.faction != SliceConstants.Owner.NEUTRAL and not _focused_once:
		_focused_once = true
		var spawn := WorldState.spawn_block(session.faction)
		camera.focus_block(spawn.block_x, spawn.block_y)
	_push_camera_block()


func _on_camera_block_changed(block_x: int, block_y: int) -> void:
	_camera_block = Vector2i(block_x, block_y)
	_push_camera_block()


## Camera interest follows the look-at block; sent once per block while the round runs.
func _push_camera_block() -> void:
	if _camera_block == _camera_block_sent or not session.match_started:
		return
	if stub != null:
		stub.set_camera_block(_camera_block.x, _camera_block.y)
	elif connection.is_online():
		GameNet.set_camera_local(_camera_block.x, _camera_block.y)
	else:
		return
	_camera_block_sent = _camera_block


func _on_tax_rate_committed(rate: float) -> void:
	if not session.can_act():
		return
	session.send_command(GameCommand.set_tax_rate(rate))


func _on_hover_changed(cell: Vector2i) -> void:
	if cell == CameraRig.NO_TILE:
		hud.hover_text = ""
	else:
		var view := session.view_tile(cell.x, cell.y)
		hud.hover_text = "tile %d,%d  %s %s" % [
			cell.x, cell.y, ClientSession.faction_name(view.owner), ClientSession.zone_name(view.zone)
		]


func _refresh_connection_text() -> void:
	if stub != null:
		hud.connection_text = "Stub server (offline, --stub)"
		hud.connection_warn = false
		return
	hud.connection_text = connection.status_text()
	hud.connection_warn = (
		connection.state == ClientConnection.State.OFFLINE
		or connection.state == ClientConnection.State.CONNECTING
	)


func _size_ground() -> void:
	var mesh := PlaneMesh.new()
	var map_size := float(SliceConstants.MAP_SIZE)
	mesh.size = Vector2(map_size, map_size)
	ground.mesh = mesh
	ground.position = Vector3(map_size * 0.5, 0.0, map_size * 0.5)
	var material := StandardMaterial3D.new()
	material.albedo_color = Palette.GROUND
	material.roughness = 1.0
	ground.material_override = material


func _take_screenshot() -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(_screenshot_path)
	print("SCREENSHOT %s %s %dx%d" % [_screenshot_path, error_string(err), image.get_width(), image.get_height()])
	get_tree().quit(0 if err == OK else 1)

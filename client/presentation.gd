extends Node3D

## Camera and a thin command surface. Rules stay on the listen-host.
## H host, J join 127.0.0.1, arrows move the cursor, Enter claims,
## Z sets zone R, E adds an edge to +X, P places power, Backspace demolishes.
## The cursor is the player view. After MatchStart, its 8×8 block is sent
## with set_camera_local so the camera interest follows that view.
##   godot --path . -- --listen
##   godot --path . -- --join 127.0.0.1

@onready var camera: Camera3D = $Camera
@onready var label: Label = $Hud/StubLabel

var session: ClientSession
var cursor := Vector2i(8, 0)
var _camera_block := Vector2i(-1, -1)


func _ready() -> void:
	_frame_map()
	session = ClientSession.new()
	session.name = "Session"
	session.updated.connect(_refresh_label)
	add_child(session)
	GameNet.faction_assigned.connect(_on_faction)
	if GameNet.has_flag("--listen"):
		var err := GameNet.host(GameNet.port_from_args())
		if err != OK:
			push_error("ENet listen failed (%s)" % error_string(err))
	elif GameNet.has_flag("--join"):
		var join_err := GameNet.join(GameNet.host_from_args(), GameNet.port_from_args())
		if join_err != OK:
			push_error("ENet join failed (%s)" % error_string(join_err))
	_refresh_label()


func _frame_map() -> void:
	var map_size := float(SliceConstants.MAP_SIZE)
	var target := Vector3(map_size * 0.5, 0.0, map_size * 0.5)
	var pitch_deg := 65.0
	var dist := 56.0
	var pitch := deg_to_rad(pitch_deg)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.current = true
	camera.size = map_size + 8.0
	camera.rotation_degrees = Vector3(-pitch_deg, 0.0, 0.0)
	camera.position = target + Vector3(0.0, dist * sin(pitch), dist * cos(pitch))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_H:
				GameNet.host(GameNet.port_from_args())
				return
			KEY_J:
				GameNet.join(GameNet.DEFAULT_JOIN_HOST, GameNet.port_from_args())
				return
			KEY_Z:
				session.send_command(GameCommand.set_zone(cursor.x, cursor.y, SliceConstants.Zone.R))
				return
			KEY_E:
				session.send_command(GameCommand.add_edge(cursor, cursor + Vector2i(1, 0)))
				return
			KEY_P:
				session.send_command(GameCommand.place_power(cursor.x, cursor.y))
				return
			KEY_BACKSPACE:
				session.send_command(GameCommand.demolish_own(cursor.x, cursor.y))
				return
	if event.is_action_pressed("ui_accept"):
		session.send_command(GameCommand.claim_tile(cursor.x, cursor.y))
	elif event.is_action_pressed("ui_left"):
		cursor.x = maxi(0, cursor.x - 1)
	elif event.is_action_pressed("ui_right"):
		cursor.x = mini(SliceConstants.MAP_SIZE - 1, cursor.x + 1)
	elif event.is_action_pressed("ui_up"):
		cursor.y = maxi(0, cursor.y - 1)
	elif event.is_action_pressed("ui_down"):
		cursor.y = mini(SliceConstants.MAP_SIZE - 1, cursor.y + 1)
	else:
		return
	_refresh_label()


func _on_faction(assigned: int) -> void:
	if assigned == SliceConstants.Owner.FACTION_B:
		cursor = Vector2i(55, 56)
	else:
		cursor = Vector2i(8, 0)
	_refresh_label()


func _refresh_label() -> void:
	_sync_camera_block()
	label.text = session.status_text(cursor)


func _sync_camera_block() -> void:
	if session == null or not session.match_started:
		return
	var block := InterestId.from_tile(cursor.x, cursor.y)
	var next := Vector2i(block.block_x, block.block_y)
	if next == _camera_block:
		return
	_camera_block = next
	GameNet.set_camera_local(next.x, next.y)

extends Node

## Headless listen-host entry. Same authority as a client that presses H.
##   godot --headless --path . res://server/main.tscn -- --port 24567
## Smoke host (ends the match after the remote peer's scripted commands):
##   godot --headless --path . res://server/main.tscn -- --port 24671 --smoke-host

func _ready() -> void:
	if GameNet.has_flag("--smoke-host"):
		GameNet.smoke_drop_after_remote = GameNet.SMOKE_REMOTE_COMMANDS
		GameNet.match_began.connect(_on_smoke_match_began)
	var err := GameNet.host(GameNet.port_from_args())
	if err != OK:
		push_error("ENet listen failed (%s)" % error_string(err))
		get_tree().quit(1)


func _on_smoke_match_began() -> void:
	call_deferred("_smoke_act")


func _smoke_act() -> void:
	GameNet.submit_local(GameCommand.set_zone(0, 0, SliceConstants.Zone.R))
	GameNet.submit_local(GameCommand.add_edge(Vector2i(0, 0), Vector2i(1, 0)))
	GameNet.submit_local(GameCommand.claim_tile(8, 0))


func _exit_tree() -> void:
	if GameNet.phase == GameNet.Phase.PLAY:
		GameNet.notify_host_dropped()

extends Node

## Authoritative match lifecycle stub.
## Listen-host for the slice is this same simulation. ENet / MultiplayerAPI
## are not wired yet (see docs/briefs/netcode-interface-v0.md).
##
## Headless:
##   godot --headless --path . res://server/main.tscn

enum Phase { LOBBY, PLAY, ENDED }

var phase: Phase = Phase.LOBBY
var tick_index: int = 0
var _timer: Timer


func _ready() -> void:
	_timer = Timer.new()
	_timer.name = "SimTick"
	_timer.wait_time = SliceConstants.SIM_TICK_SEC
	_timer.timeout.connect(_on_sim_tick)
	add_child(_timer)
	start_match()


func start_match() -> void:
	if phase == Phase.PLAY:
		return
	phase = Phase.PLAY
	tick_index = 0
	_timer.start()
	print("MatchStart")


func end_match(reason: String) -> void:
	if phase == Phase.ENDED:
		return
	phase = Phase.ENDED
	_timer.stop()
	print("MatchEnd: %s" % reason)


## Slice rule: if the host drops, the match ends. Not hooked to a peer yet.
func notify_host_dropped() -> void:
	end_match("host_drop")


## Returns a ReasonCode.Id. Rules are not implemented; valid calls reject
## with NOT_IMPLEMENTED so the client can roll back optimistic UI later.
func submit_command(cmd: GameCommand) -> int:
	if phase != Phase.PLAY:
		return ReasonCode.Id.MATCH_NOT_ACTIVE
	if cmd == null:
		return ReasonCode.Id.UNKNOWN_COMMAND
	return ReasonCode.Id.NOT_IMPLEMENTED


func _on_sim_tick() -> void:
	if phase != Phase.PLAY:
		return
	tick_index += 1
	# Later: powerCovered, population, congestion. Nothing is simulated yet.

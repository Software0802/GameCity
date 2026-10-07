extends Node

## Listen-host authority. ENet + MultiplayerAPI, reliable ordered RPCs.
## The host peer runs this same node; clients only send intents.
## Default listen port is 24567. Host drop ends the match (no migration).
##
## Autoload name: GameNet. Path /root/GameNet is identical on every peer.

signal faction_assigned(faction: int)
signal event_received(event: ServerEvent)
signal match_began
signal phase_changed(phase: int)

enum Phase { LOBBY, PLAY, ENDED }

const DEFAULT_PORT := 24567
const DEFAULT_JOIN_HOST := "127.0.0.1"
## Client smoke sends this many remote commands, then the host ends the match.
const SMOKE_REMOTE_COMMANDS := 5
const EVENT_BATCH := 32

var phase: Phase = Phase.LOBBY
var tick_index: int = 0
var world: WorldState = null
var smoke_drop_after_remote: int = -1

var _timer: Timer
var _join_order: Array[int] = []
var _peers: Dictionary = {}
var _remote_command_count: int = 0


func _ready() -> void:
	_timer = Timer.new()
	_timer.name = "SimTick"
	_timer.wait_time = SliceConstants.SIM_TICK_SEC
	_timer.timeout.connect(_on_sim_tick)
	add_child(_timer)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func host(port: int = DEFAULT_PORT) -> Error:
	if _enet_active():
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var max_clients := maxi(1, SliceConstants.PLAYERS_MAX - 1)
	var err := peer.create_server(port, max_clients)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_register_peer(multiplayer.get_unique_id())
	print("Listen %d (lobby until %d peers)" % [port, SliceConstants.PLAYERS_MIN])
	return OK


func join(address: String, port: int = DEFAULT_PORT) -> Error:
	close_peer()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	print("Join %s:%d" % [address, port])
	return OK


func close_peer() -> void:
	if not _enet_active():
		return
	multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null


func submit_local(cmd: GameCommand) -> void:
	if cmd == null or not _enet_active():
		return
	if multiplayer.is_server():
		_handle_command(multiplayer.get_unique_id(), cmd)
	else:
		submit_command_rpc.rpc_id(1, cmd.to_dict())


func set_camera_local(block_x: int, block_y: int) -> void:
	if not _enet_active():
		return
	if multiplayer.is_server():
		_set_camera(multiplayer.get_unique_id(), block_x, block_y)
	else:
		set_camera_block_rpc.rpc_id(1, block_x, block_y)


func notify_host_dropped() -> void:
	_end(SliceConstants.Owner.NEUTRAL, "host_drop")


func start_match() -> void:
	if phase != Phase.LOBBY:
		return
	world = WorldState.new()
	phase = Phase.PLAY
	tick_index = 0
	_timer.start()
	print("MatchStart")
	for peer_id in _join_order:
		_send_join_bundle(peer_id)
	match_began.emit()
	phase_changed.emit(phase)


static func has_flag(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag)


static func arg_value(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var idx := args.find(flag)
	if idx == -1 or idx + 1 >= args.size():
		return fallback
	var value := str(args[idx + 1])
	if value.begins_with("--"):
		return fallback
	return value


static func port_from_args() -> int:
	return int(arg_value("--port", str(DEFAULT_PORT)))


static func host_from_args() -> String:
	return arg_value("--join", DEFAULT_JOIN_HOST)


@rpc("any_peer", "reliable")
func submit_command_rpc(data: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	_handle_command(multiplayer.get_remote_sender_id(), GameCommand.from_dict(data))


@rpc("any_peer", "reliable")
func set_camera_block_rpc(block_x: int, block_y: int) -> void:
	if not multiplayer.is_server():
		return
	_set_camera(multiplayer.get_remote_sender_id(), block_x, block_y)


@rpc("authority", "reliable")
func welcome_rpc(faction: int) -> void:
	faction_assigned.emit(faction)


@rpc("authority", "reliable")
func server_events_rpc(packed: Array) -> void:
	for entry in packed:
		if entry is Dictionary:
			event_received.emit(ServerEvent.from_dict(entry))


func _on_peer_connected(peer_id: int) -> void:
	if not _enet_active() or not multiplayer.is_server():
		return
	_register_peer(peer_id)
	if phase == Phase.LOBBY and _join_order.size() >= SliceConstants.PLAYERS_MIN:
		start_match()
	elif phase == Phase.PLAY:
		_send_join_bundle(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if not _enet_active() or not multiplayer.is_server():
		return
	_peers.erase(peer_id)
	_join_order.erase(peer_id)


func _on_server_disconnected() -> void:
	# OfflineMultiplayerPeer is the editor default and reports as server.
	# Only a connected client should treat this as the listen-host dropping.
	if multiplayer.is_server():
		return
	_end(SliceConstants.Owner.NEUTRAL, "host_drop")


func _on_sim_tick() -> void:
	if phase != Phase.PLAY or world == null:
		return
	tick_index += 1
	_publish_events(world.sim_tick(tick_index))


func _register_peer(peer_id: int) -> void:
	if _peers.has(peer_id):
		return
	var faction := SliceConstants.Owner.FACTION_A
	if _join_order.size() % 2 == 1:
		faction = SliceConstants.Owner.FACTION_B
	_join_order.append(peer_id)
	_peers[peer_id] = {
		"faction": faction,
		"camera": WorldState.spawn_block(faction),
		"subscribed": {},
	}


func _handle_command(peer_id: int, cmd: GameCommand) -> void:
	if not _peers.has(peer_id) or cmd == null:
		return
	var faction: int = _peers[peer_id]["faction"]
	var reason := ReasonCode.Id.OK
	var detail := ""
	if phase != Phase.PLAY or world == null:
		reason = ReasonCode.Id.MATCH_NOT_ACTIVE
		_reject(peer_id, cmd, reason, detail)
	else:
		var result: Dictionary = world.apply(faction, cmd)
		reason = int(result["reason"])
		detail = str(result["detail"])
		if reason != ReasonCode.Id.OK:
			_reject(peer_id, cmd, reason, detail)
		else:
			_refresh_all_interest()
			_publish_events(result["events"])
	print("command peer=%d faction=%d kind=%d reason=%d" % [peer_id, faction, cmd.kind, reason])
	_note_remote(peer_id)


func _note_remote(peer_id: int) -> void:
	if not _enet_active() or peer_id == multiplayer.get_unique_id():
		return
	_remote_command_count += 1
	if smoke_drop_after_remote > 0 and _remote_command_count >= smoke_drop_after_remote:
		smoke_drop_after_remote = -1
		notify_host_dropped.call_deferred()


func _reject(peer_id: int, cmd: GameCommand, reason: int, detail: String) -> void:
	var reject := CommandReject.new(cmd, reason, detail)
	_send_many(peer_id, [ServerEvent.with_reject(reject)])


func _set_camera(peer_id: int, block_x: int, block_y: int) -> void:
	if phase != Phase.PLAY or world == null or not _peers.has(peer_id):
		return
	_peers[peer_id]["camera"] = InterestId.new(block_x, block_y)
	_refresh_interest(peer_id)


func _send_join_bundle(peer_id: int) -> void:
	_send_welcome(peer_id)
	_send_many(peer_id, [ServerEvent.with_match_start(MatchStart.new())])
	_refresh_interest(peer_id)


func _send_welcome(peer_id: int) -> void:
	var faction: int = _peers[peer_id]["faction"]
	if _is_local(peer_id):
		faction_assigned.emit(faction)
		return
	welcome_rpc.rpc_id(peer_id, faction)


func _refresh_all_interest() -> void:
	for peer_id in _join_order:
		_refresh_interest(peer_id)


func _refresh_interest(peer_id: int) -> void:
	if world == null or not _peers.has(peer_id):
		return
	var slot: Dictionary = _peers[peer_id]
	var subscribed: Dictionary = slot["subscribed"]
	var new_keys: Dictionary = {}
	for block in world.interest_for(slot["faction"], slot["camera"]):
		new_keys[block.key()] = block
	var update := InterestUpdate.new()
	for key in new_keys:
		if not subscribed.has(key):
			update.add.append(new_keys[key])
	for key in subscribed:
		if not new_keys.has(key):
			update.remove.append(InterestId.from_key(str(key)))
	var replaced: Dictionary = {}
	for key in new_keys:
		replaced[key] = true
	slot["subscribed"] = replaced
	if update.add.is_empty() and update.remove.is_empty():
		return
	_send_many(peer_id, [ServerEvent.with_interest_update(update)])
	for block in update.add:
		_send_block_snapshot(peer_id, block)


func _send_block_snapshot(peer_id: int, block: InterestId) -> void:
	var events: Array = []
	for tile in world.tiles_in_block(block):
		events.append(ServerEvent.with_tile_delta(tile))
	for edge in world.edges_in_block(block):
		events.append(ServerEvent.with_edge_delta(edge))
	_send_many(peer_id, events)


func _publish_events(events: Array) -> void:
	var global_events: Array = []
	var local_events: Array = []
	for event in events:
		if _is_global(int(event.kind)):
			global_events.append(event)
		else:
			local_events.append(event)
	for event in global_events:
		_broadcast_all(event)
	if local_events.is_empty():
		return
	for peer_id in _join_order:
		var deliver: Array = []
		var summary_keys: Dictionary = {}
		for event in local_events:
			var blocks := _event_blocks(event)
			if _peer_sees_any(peer_id, blocks):
				deliver.append(event)
			else:
				for block in blocks:
					summary_keys[block.key()] = block
		for key in summary_keys:
			deliver.append(ServerEvent.with_region_summary(world.summary_for(summary_keys[key])))
		_send_many(peer_id, deliver)


func _broadcast_all(event: ServerEvent) -> void:
	if _join_order.is_empty():
		event_received.emit(event)
		return
	for peer_id in _join_order:
		_send_many(peer_id, [event])


func _send_many(peer_id: int, events: Array) -> void:
	var packed: Array = []
	for event in events:
		packed.append(event.to_dict())
		if packed.size() >= EVENT_BATCH:
			_deliver(peer_id, packed)
			packed = []
	if not packed.is_empty():
		_deliver(peer_id, packed)


func _deliver(peer_id: int, packed: Array) -> void:
	if _is_local(peer_id):
		for entry in packed:
			event_received.emit(ServerEvent.from_dict(entry))
		return
	server_events_rpc.rpc_id(peer_id, packed)


func _enet_active() -> bool:
	return multiplayer.multiplayer_peer is ENetMultiplayerPeer


func _is_local(peer_id: int) -> bool:
	if not _enet_active():
		return true
	return peer_id == multiplayer.get_unique_id()


func _peer_sees_any(peer_id: int, blocks: Array) -> bool:
	if not _peers.has(peer_id):
		return false
	var subscribed: Dictionary = _peers[peer_id]["subscribed"]
	if blocks.is_empty():
		return true
	for block in blocks:
		if subscribed.has(block.key()):
			return true
	return false


func _event_blocks(event: ServerEvent) -> Array:
	var blocks: Array = []
	match event.kind:
		ServerEvent.Kind.TILE_DELTA:
			if event.tile_delta != null:
				blocks.append(InterestId.from_tile(event.tile_delta.x, event.tile_delta.y))
		ServerEvent.Kind.POWER_ALERT:
			if event.power_alert != null:
				blocks.append(InterestId.from_tile(event.power_alert.x, event.power_alert.y))
		ServerEvent.Kind.EDGE_DELTA:
			if event.edge_delta != null:
				_append_edge_blocks(blocks, event.edge_delta.a, event.edge_delta.b)
		ServerEvent.Kind.CONGESTION_ALERT:
			if event.congestion_alert != null:
				_append_edge_blocks(blocks, event.congestion_alert.a, event.congestion_alert.b)
		ServerEvent.Kind.REGION_SUMMARY:
			if event.region_summary != null and event.region_summary.interest != null:
				blocks.append(event.region_summary.interest)
	return blocks


func _append_edge_blocks(blocks: Array, a: Vector2i, b: Vector2i) -> void:
	var block_a := InterestId.from_tile(a.x, a.y)
	var block_b := InterestId.from_tile(b.x, b.y)
	blocks.append(block_a)
	if block_b.key() != block_a.key():
		blocks.append(block_b)


func _is_global(kind: int) -> bool:
	return (
		kind == ServerEvent.Kind.SCORE_TICK
		or kind == ServerEvent.Kind.CRISIS_EVENT
		or kind == ServerEvent.Kind.MATCH_START
		or kind == ServerEvent.Kind.MATCH_END
	)


func _end(winner: int, reason: String) -> void:
	if phase == Phase.ENDED:
		return
	phase = Phase.ENDED
	_timer.stop()
	var body := MatchEnd.new()
	body.winner = winner
	body.reason = reason
	_broadcast_all(ServerEvent.with_match_end(body))
	print("MatchEnd: %s" % reason)
	phase_changed.emit(phase)

extends Node

## Dedicated-server authority and the client's thin transport. ENet + MultiplayerAPI,
## reliable ordered RPCs. Autoload name GameNet; /root/GameNet is the same path on
## every peer, which is what the RPCs key on.
##
## Server process (res://server/main.tscn, driven by server/match_sim.gd): there is
## no local player. A connection is "pending" until its hello_rpc passes; only then
## does it become a player and receive WELCOME → MATCH_START → interest snapshot.
## Commands from a pending connection are rejected NOT_AUTHENTICATED. This file owns
## sessions, the handshake, command handling, and event routing. The round clock,
## sim tick, saves, and status file live in match_sim.gd.
##
## Client process: join() → (auto) hello() → WELCOME, MATCH_START, snapshot →
## submit_local() / set_camera_local() → event_received. A server disconnect emits
## connection_lost; it is not a match end, the client should reconnect.

## Client: WELCOME arrived; the faction this connection plays.
signal faction_assigned(faction: int)
## Client: full WELCOME body, including the token to persist.
signal welcomed(welcome: ServerWelcome)
## Client: every server event in order, WELCOME included.
signal event_received(event: ServerEvent)
## Client: the server connection dropped after it had been established.
signal connection_lost
signal phase_changed(phase: int)
## Server: a connection finished the handshake (after its snapshot was sent).
signal player_joined(peer_id: int, player_id: int, faction: int, returning: bool)
## Server: a welcomed connection went away.
signal player_left(peer_id: int, player_id: int)
## Server: a welcomed connection's command was answered (reason is ReasonCode.Id).
signal command_handled(peer_id: int, cmd: GameCommand, reason: int)

enum Phase { IDLE, PLAY, ENDED }

const DEFAULT_PORT := 24567
const DEFAULT_JOIN_HOST := "127.0.0.1"
## Hello name when neither --name nor identity_name is set. Passes is_valid_name.
const DEFAULT_NAME := "player"
const EVENT_BATCH := 32
## A connection that has not said hello within this many seconds is dropped.
const HELLO_TIMEOUT_SEC := 10.0
## Transport slots. The player count is capped at hello by SliceConstants.PLAYERS_MAX;
## the spare slots let a reconnect land while its dropped connection times out.
const TRANSPORT_MAX_CLIENTS := SliceConstants.PLAYERS_MAX * 2

var phase: Phase = Phase.IDLE
## Server: authoritative world and player table. match_sim.gd sets both before
## start_server().
var world: WorldState = null
var players: Players = null
## Server: round clock as echoed in MatchStart. match_sim.gd sets these.
var round_started_at_unix: int = 0
var round_ends_at_unix: int = 0
var pace: float = SliceConstants.PACE_DEFAULT

## Client identity. Defaults come from --name / --token; a client that keeps
## user://identity.cfg overwrites them before join(). After WELCOME they hold the
## issued token and confirmed name.
var auto_hello := true
var identity_name := ""
var identity_token := ""
var player_id := -1
var faction: int = SliceConstants.Owner.NEUTRAL

var _housekeeping: Timer
## peer_id → Time.get_ticks_msec() at connect, for connections without a hello yet.
var _pending: Dictionary = {}
## peer_id → {player_id, faction, camera: InterestId, subscribed: {key: true}}.
var _peers: Dictionary = {}
var _join_order: Array[int] = []
var _match_end: MatchEnd = null


func _ready() -> void:
	identity_name = arg_value("--name", "")
	identity_token = arg_value("--token", "")
	_housekeeping = Timer.new()
	_housekeeping.name = "Housekeeping"
	_housekeeping.wait_time = 1.0
	_housekeeping.timeout.connect(_on_housekeeping)
	add_child(_housekeeping)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# ---------------------------------------------------------------- server API


## Opens the ENet listen socket. world and players must already be set.
func start_server(port: int) -> Error:
	if _enet_active():
		return ERR_ALREADY_IN_USE
	if world == null or players == null:
		push_error("GameNet.start_server: world and players must be set first")
		return ERR_UNCONFIGURED
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, TRANSPORT_MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_housekeeping.start()
	print("Listen %d" % port)
	return OK


func is_server_running() -> bool:
	return _enet_active() and multiplayer.is_server()


func set_phase(next: Phase) -> void:
	if phase == next:
		return
	phase = next
	phase_changed.emit(phase)


## Ends the round for everyone. Late joiners receive the same body after their
## snapshot. A second call is ignored.
func end_round(body: MatchEnd) -> void:
	if phase == Phase.ENDED:
		return
	_match_end = body
	broadcast([ServerEvent.with_match_end(body)])
	print("MatchEnd: %s" % body.reason)
	set_phase(Phase.ENDED)


## Boot of a save whose round already ended: remember the body for late joiners and
## enter ENDED without announcing anything (nobody is connected yet).
func restore_match_end(body: MatchEnd) -> void:
	_match_end = body
	set_phase(Phase.ENDED)


func match_end() -> MatchEnd:
	return _match_end


## Routes sim events: FACTION_STATE goes to that faction only, WELCOME never leaves
## the handshake, everything else is global or interest-routed.
func publish(events: Array) -> void:
	var routed: Array = []
	for event in events:
		if event == null:
			continue
		match int(event.kind):
			ServerEvent.Kind.FACTION_STATE:
				if event.faction_state != null:
					send_faction(event.faction_state.faction, [event])
			ServerEvent.Kind.WELCOME:
				pass
			_:
				routed.append(event)
	_publish_events(routed)


## To every welcomed connection.
func broadcast(events: Array) -> void:
	for peer_id in _join_order:
		_send_many(peer_id, events)


## To every welcomed connection of one faction.
func send_faction(p_faction: int, events: Array) -> void:
	for peer_id in _join_order:
		if int(_peers[peer_id]["faction"]) == p_faction:
			_send_many(peer_id, events)


## To one connection, pending or welcomed.
func send_peer(peer_id: int, events: Array) -> void:
	if _peers.has(peer_id) or _pending.has(peer_id):
		_send_many(peer_id, events)


func online_count() -> int:
	return _join_order.size()


func online_peers() -> Array[int]:
	return _join_order.duplicate()


## SliceConstants.Owner of a welcomed connection, NEUTRAL otherwise.
func peer_faction(peer_id: int) -> int:
	if not _peers.has(peer_id):
		return SliceConstants.Owner.NEUTRAL
	return int(_peers[peer_id]["faction"])


## Marks every welcomed player as seen now (called right before a save).
func touch_online_players(now_unix: int) -> void:
	if players == null:
		return
	for peer_id in _join_order:
		players.touch(int(_peers[peer_id]["player_id"]), now_unix)


## MatchStart for the current round; server_unix is read when it is built.
func build_match_start() -> MatchStart:
	var body := MatchStart.new()
	body.round_seconds = round_ends_at_unix - round_started_at_unix
	body.round_ends_at_unix = round_ends_at_unix
	body.server_unix = int(Time.get_unix_time_from_system())
	body.pace = pace
	return body


# ---------------------------------------------------------------- client API


## Connects to a server. The hello goes out on connected_to_server when auto_hello
## is true, using p_name / p_token when given, else identity_name / identity_token.
func join(address: String, port: int = DEFAULT_PORT, p_name: String = "", p_token: String = "") -> Error:
	close_peer()
	if not p_name.is_empty():
		identity_name = p_name
	if not p_token.is_empty():
		identity_token = p_token
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	print("Join %s:%d" % [address, port])
	return OK


## Sends ClientHello to the server. Empty name falls back to identity_name, then
## DEFAULT_NAME; empty token to identity_token (a first visit sends "").
func hello(p_name: String = "", p_token: String = "", protocol: int = SliceConstants.PROTOCOL_VERSION) -> void:
	if not _client_connected():
		return
	if not p_name.is_empty():
		identity_name = p_name
	if not p_token.is_empty():
		identity_token = p_token
	var body := ClientHello.new()
	body.name = identity_name if not identity_name.is_empty() else DEFAULT_NAME
	body.token = identity_token
	body.protocol = protocol
	hello_rpc.rpc_id(1, body.to_dict())


## Listen-host is gone: the only server is res://server/main.tscn. This stub keeps
## the H key / --listen path in client/presentation.gd compiling until client-play
## removes it; it never opens a socket.
func host(_port: int = DEFAULT_PORT) -> Error:
	push_warning("GameNet.host: listen-host was removed; run res://server/main.tscn")
	return ERR_UNAVAILABLE


func close_peer() -> void:
	if not _enet_active():
		return
	multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null


func submit_local(cmd: GameCommand) -> void:
	if cmd == null or not _client_connected():
		return
	submit_command_rpc.rpc_id(1, cmd.to_dict())


func set_camera_local(block_x: int, block_y: int) -> void:
	if not _client_connected():
		return
	set_camera_block_rpc.rpc_id(1, block_x, block_y)


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


# ---------------------------------------------------------------- RPC surface


@rpc("any_peer", "reliable")
func hello_rpc(data: Dictionary) -> void:
	if not is_server_running():
		return
	_handle_hello(multiplayer.get_remote_sender_id(), ClientHello.from_dict(data))


@rpc("any_peer", "reliable")
func submit_command_rpc(data: Dictionary) -> void:
	if not is_server_running():
		return
	_handle_command(multiplayer.get_remote_sender_id(), GameCommand.from_dict(data))


@rpc("any_peer", "reliable")
func set_camera_block_rpc(block_x: int, block_y: int) -> void:
	if not is_server_running():
		return
	_set_camera(multiplayer.get_remote_sender_id(), block_x, block_y)


@rpc("authority", "reliable")
func server_events_rpc(packed: Array) -> void:
	for entry in packed:
		if not (entry is Dictionary):
			continue
		var event := ServerEvent.from_dict(entry)
		if event.kind == ServerEvent.Kind.WELCOME and event.welcome != null:
			identity_token = event.welcome.token
			identity_name = event.welcome.name
			player_id = event.welcome.player_id
			faction = event.welcome.faction
			welcomed.emit(event.welcome)
			faction_assigned.emit(faction)
		event_received.emit(event)


# ---------------------------------------------------------------- transport signals


func _on_peer_connected(peer_id: int) -> void:
	if not is_server_running():
		return
	_pending[peer_id] = Time.get_ticks_msec()
	print("peer %d connected, waiting for hello" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_server_running():
		return
	_pending.erase(peer_id)
	if not _peers.has(peer_id):
		return
	var left_player := int(_peers[peer_id]["player_id"])
	if players != null:
		players.touch(left_player, int(Time.get_unix_time_from_system()))
	_peers.erase(peer_id)
	_join_order.erase(peer_id)
	print("peer %d disconnected player=%d (kept)" % [peer_id, left_player])
	player_left.emit(peer_id, left_player)


func _on_connected_to_server() -> void:
	if auto_hello:
		hello()


func _on_server_disconnected() -> void:
	# OfflineMultiplayerPeer is the editor default and reports as server; only a
	# connected client should treat this as losing the server.
	if multiplayer.is_server():
		return
	if _enet_active():
		multiplayer.multiplayer_peer = null
	connection_lost.emit()


func _on_housekeeping() -> void:
	if not is_server_running():
		return
	var now_ms := Time.get_ticks_msec()
	for peer_id in _pending.keys():
		if now_ms - int(_pending[peer_id]) > int(HELLO_TIMEOUT_SEC * 1000.0):
			_refuse(peer_id, "hello_timeout")


# ---------------------------------------------------------------- handshake


func _handle_hello(peer_id: int, hello_body: ClientHello) -> void:
	if _peers.has(peer_id):
		print("hello ignored: peer %d already welcomed" % peer_id)
		return
	if not _pending.has(peer_id):
		return
	if hello_body.protocol != SliceConstants.PROTOCOL_VERSION:
		_refuse(peer_id, "protocol %d != %d" % [hello_body.protocol, SliceConstants.PROTOCOL_VERSION])
		return
	if not ClientHello.is_valid_name(hello_body.name):
		_refuse(peer_id, "name")
		return
	var now := int(Time.get_unix_time_from_system())
	var token := hello_body.token
	var record: Players.Record = null
	if not token.is_empty():
		record = players.find_by_token_hash(Players.hash_token(token))
	var returning := record != null
	if record == null:
		if players.size() >= SliceConstants.PLAYERS_MAX:
			_refuse(peer_id, "server_full")
			return
		token = Players.new_token()
		record = players.create(hello_body.name, players.pick_faction(), Players.hash_token(token), now)
	else:
		record.name = hello_body.name
		record.last_seen_unix = now
	_pending.erase(peer_id)
	_peers[peer_id] = {
		"player_id": record.player_id,
		"faction": record.faction,
		"camera": WorldState.spawn_block(record.faction),
		"subscribed": {},
	}
	_join_order.append(peer_id)
	var welcome := ServerWelcome.new()
	welcome.token = token
	welcome.player_id = record.player_id
	welcome.faction = record.faction
	welcome.name = record.name
	welcome.returning = returning
	_send_many(peer_id, [ServerEvent.with_welcome(welcome)])
	_send_many(peer_id, [ServerEvent.with_match_start(build_match_start())])
	_refresh_interest(peer_id)
	if phase == Phase.ENDED and _match_end != null:
		_send_many(peer_id, [ServerEvent.with_match_end(_match_end)])
	print("welcome peer=%d player=%d faction=%d returning=%s name=%s" % [
		peer_id, record.player_id, record.faction, returning, record.name
	])
	player_joined.emit(peer_id, record.player_id, record.faction, returning)


## Answers a failed hello with Reject(NOT_AUTHENTICATED, detail) and disconnects the
## connection once that packet has gone out.
func _refuse(peer_id: int, detail: String) -> void:
	print("hello refused peer=%d %s" % [peer_id, detail])
	_send_many(peer_id, [ServerEvent.with_reject(CommandReject.new(null, ReasonCode.Id.NOT_AUTHENTICATED, detail))])
	_pending.erase(peer_id)
	_disconnect_later(peer_id)


func _disconnect_later(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var packet_peer := enet.get_peer(peer_id)
	if packet_peer != null:
		packet_peer.peer_disconnect_later()
	else:
		enet.disconnect_peer(peer_id)


# ---------------------------------------------------------------- commands


func _handle_command(peer_id: int, cmd: GameCommand) -> void:
	if not _peers.has(peer_id):
		if _pending.has(peer_id):
			_reject(peer_id, cmd, ReasonCode.Id.NOT_AUTHENTICATED, "hello_first")
			print("command peer=%d rejected: not authenticated" % peer_id)
		return
	if cmd == null:
		return
	var sender_faction := int(_peers[peer_id]["faction"])
	var reason := ReasonCode.Id.OK
	if phase != Phase.PLAY or world == null:
		reason = ReasonCode.Id.MATCH_NOT_ACTIVE
		_reject(peer_id, cmd, reason, "")
	else:
		var result: Dictionary = world.apply(sender_faction, cmd)
		reason = int(result["reason"])
		if reason != ReasonCode.Id.OK:
			_reject(peer_id, cmd, reason, str(result["detail"]))
		else:
			_refresh_all_interest()
			publish(result["events"])
	print("command peer=%d faction=%d kind=%d reason=%d" % [peer_id, sender_faction, cmd.kind, reason])
	command_handled.emit(peer_id, cmd, reason)


func _reject(peer_id: int, cmd: GameCommand, reason: int, detail: String) -> void:
	_send_many(peer_id, [ServerEvent.with_reject(CommandReject.new(cmd, reason, detail))])


func _set_camera(peer_id: int, block_x: int, block_y: int) -> void:
	if world == null or not _peers.has(peer_id):
		return
	_peers[peer_id]["camera"] = InterestId.new(block_x, block_y)
	_refresh_interest(peer_id)


# ---------------------------------------------------------------- interest routing


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


## Global kinds go to everyone; the rest go to subscribers of the event's blocks,
## with a RegionSummary for peers that only see the block from outside. An event
## with no block (none of the kinds below) reaches every welcomed peer.
func _publish_events(events: Array) -> void:
	var global_events: Array = []
	var local_events: Array = []
	for event in events:
		if _is_global(int(event.kind)):
			global_events.append(event)
		else:
			local_events.append(event)
	if not global_events.is_empty():
		broadcast(global_events)
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


func _send_many(peer_id: int, events: Array) -> void:
	var packed: Array = []
	for event in events:
		packed.append(event.to_dict())
		if packed.size() >= EVENT_BATCH:
			server_events_rpc.rpc_id(peer_id, packed)
			packed = []
	if not packed.is_empty():
		server_events_rpc.rpc_id(peer_id, packed)


func _enet_active() -> bool:
	return multiplayer.multiplayer_peer is ENetMultiplayerPeer


func _client_connected() -> bool:
	return (
		_enet_active()
		and not multiplayer.is_server()
		and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	)


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


## WELCOME and FACTION_STATE are deliberately absent: publish() handles them before
## routing, so neither can fall through to the "no block → everyone" default.
func _is_global(kind: int) -> bool:
	return (
		kind == ServerEvent.Kind.SCORE_TICK
		or kind == ServerEvent.Kind.CRISIS_EVENT
		or kind == ServerEvent.Kind.MATCH_START
		or kind == ServerEvent.Kind.MATCH_END
	)

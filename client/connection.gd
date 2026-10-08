class_name ClientConnection
extends Node

## Client side of the transport and the handshake. Joins the server, sends
## ClientHello through GameNet.hello_rpc once the transport connects, stores the
## token from WELCOME, and after a drop retries every RETRY_SEC with that token.
## GameNet.auto_hello is switched off before each join so only this hello (with the
## stored token) reaches the server; otherwise a token-less hello would register a
## new player first and the reconnect would come back with returning = false.
##
## Until server-core lands hello_rpc, the host announces the faction with the
## faction_assigned signal and never sends WELCOME; that path is accepted as
## "authenticated without a token" so the client stays usable against it.

signal state_changed(state: int)

enum State { OFFLINE, CONNECTING, CONNECTED, AUTHENTICATED }

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 24567
const RETRY_SEC := 2.0
const CONNECT_TIMEOUT_SEC := 4.0
## ENet drop detection for the server peer: ENet's defaults wait 5–30 s of unanswered
## pings; these bring a dead server down to 2–10 s so the reconnect prompt is prompt. The
## ceiling is 10 s rather than 4 s because macOS blocks the main loop for several seconds
## while a window is dragged or resized, and a 4 s ceiling read that as a dead server.
const ENET_TIMEOUT_LIMIT := 32
const ENET_TIMEOUT_MIN_MS := 2000
const ENET_TIMEOUT_MAX_MS := 10000

var identity: ClientIdentity = null
var host: String = DEFAULT_HOST
var port: int = DEFAULT_PORT
var state: State = State.OFFLINE
var attempts: int = 0
## Seconds until the next join attempt while OFFLINE.
var retry_left: float = 0.0
## True once hello_rpc exists on GameNet (handshake server merged).
var hello_supported: bool = false
var ever_connected: bool = false
var last_failure: String = ""

var _active := false
## Wall-clock marks: a throttled process (macOS App Nap on an occluded window) delivers
## _process at ~1 Hz, so timeouts measured in accumulated delta would stretch for minutes.
var _connect_started_ms := 0
var _retry_due_ms := 0


func _ready() -> void:
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func start(p_host: String, p_port: int, p_identity: ClientIdentity, session: ClientSession) -> void:
	host = p_host
	port = p_port
	identity = p_identity
	session.welcomed.connect(_on_welcomed)
	if GameNet.has_signal("faction_assigned"):
		GameNet.connect("faction_assigned", _on_legacy_faction)
	_active = true
	_try_join()


func is_online() -> bool:
	return state == State.AUTHENTICATED


func status_text() -> String:
	match state:
		State.OFFLINE:
			if ever_connected:
				return "Disconnected (%s) · reconnecting in %ds" % [last_failure, ceili(retry_left)]
			return "Connecting to %s:%d · retry in %ds (attempt %d)" % [host, port, ceili(retry_left), attempts]
		State.CONNECTING:
			return "Connecting to %s:%d" % [host, port]
		State.CONNECTED:
			if hello_supported:
				return "Connected · waiting for WELCOME"
			return "Connected · host without handshake"
		_:
			var token := " · token" if identity != null and identity.has_token() else ""
			return "Online %s:%d%s" % [host, port, token]


func _process(delta: float) -> void:
	if not _active:
		return
	match state:
		State.OFFLINE:
			retry_left = maxf(0.0, float(_retry_due_ms - Time.get_ticks_msec()) / 1000.0)
			if retry_left <= 0.0:
				_try_join()
		State.CONNECTING:
			if Time.get_ticks_msec() - _connect_started_ms > int(CONNECT_TIMEOUT_SEC * 1000.0):
				_fail("timeout")
		_:
			pass


func _try_join() -> void:
	attempts += 1
	_connect_started_ms = Time.get_ticks_msec()
	# The handshake server's GameNet sends its own hello on connect (auto_hello, from
	# --name / --token) unless told not to; this client sends hello itself with the
	# token from the identity file, so that path is switched off before every join.
	# Object.set is a no-op on a GameNet that has no such property.
	GameNet.set("auto_hello", false)
	var err: Error = GameNet.join(host, port)
	if err != OK:
		_fail(error_string(err))
		return
	_set_state(State.CONNECTING)


func _on_connected() -> void:
	ever_connected = true
	_tighten_enet_timeout()
	# Decide before the CONNECTED status line is logged, or it reads "host without handshake".
	hello_supported = GameNet.has_method("hello_rpc")
	_set_state(State.CONNECTED)
	_send_hello()


func _tighten_enet_timeout() -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null:
		return
	var server_peer: ENetPacketPeer = enet.get_peer(1)
	if server_peer == null:
		return
	server_peer.set_timeout(ENET_TIMEOUT_LIMIT, ENET_TIMEOUT_MIN_MS, ENET_TIMEOUT_MAX_MS)


func _send_hello() -> void:
	if not hello_supported:
		return
	var hello := identity.hello()
	GameNet.rpc_id(1, &"hello_rpc", hello.to_dict())


func _on_welcomed(welcome: ServerWelcome) -> void:
	if identity != null:
		var err := identity.accept_welcome(welcome)
		if err != OK:
			push_warning("identity save failed: %s" % error_string(err))
	_set_state(State.AUTHENTICATED)


## Pre-handshake host: faction arrives without WELCOME or token.
func _on_legacy_faction(_faction: int) -> void:
	if state == State.CONNECTED and not hello_supported:
		_set_state(State.AUTHENTICATED)


func _on_connection_failed() -> void:
	_fail("refused")


func _on_server_disconnected() -> void:
	_fail("server dropped")


func _fail(why: String) -> void:
	last_failure = why
	if GameNet.has_method("close_peer"):
		GameNet.close_peer()
	retry_left = RETRY_SEC
	_retry_due_ms = Time.get_ticks_msec() + int(RETRY_SEC * 1000.0)
	_set_state(State.OFFLINE)


func _set_state(next: State) -> void:
	if next == state:
		return
	state = next
	print("[connection] %s %s" % [Time.get_time_string_from_system(), status_text()])
	state_changed.emit(state)

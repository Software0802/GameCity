class_name ClientConnection
extends Node

## Client side of the transport and the handshake. Joins the server, sends
## ClientHello through GameNet.hello_rpc once the transport connects, stores the
## token from WELCOME, and after a drop retries every RETRY_SEC with that token.
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
var _connect_elapsed := 0.0


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
			retry_left -= delta
			if retry_left <= 0.0:
				_try_join()
		State.CONNECTING:
			_connect_elapsed += delta
			if _connect_elapsed > CONNECT_TIMEOUT_SEC:
				_fail("timeout")
		_:
			pass


func _try_join() -> void:
	attempts += 1
	_connect_elapsed = 0.0
	var err: Error = GameNet.join(host, port)
	if err != OK:
		_fail(error_string(err))
		return
	_set_state(State.CONNECTING)


func _on_connected() -> void:
	ever_connected = true
	_set_state(State.CONNECTED)
	_send_hello()


func _send_hello() -> void:
	hello_supported = GameNet.has_method("hello_rpc")
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
	_set_state(State.OFFLINE)


func _set_state(next: State) -> void:
	if next == state:
		return
	state = next
	state_changed.emit(state)

class_name ClientIdentity
extends RefCounted

## Local player identity: the server-issued token and the display name, stored in
## user://identity.cfg (docs/plans/m2-city-phase.md, seam "客户端身份文件").
## The path is a constructor argument so smoke tests can point two clients at two files.
##
## [identity]
## token="..."      empty before the first WELCOME
## name="player-1a2b"

const DEFAULT_PATH := "user://identity.cfg"
const SECTION := "identity"
const NAME_PREFIX := "player-"

var path: String = DEFAULT_PATH
var token: String = ""
var name: String = ""


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path


## True when the file existed and parsed. A missing file leaves token and name empty.
func load() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return false
	token = str(cfg.get_value(SECTION, "token", ""))
	name = str(cfg.get_value(SECTION, "name", ""))
	return true


func save() -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "token", token)
	cfg.set_value(SECTION, "name", name)
	var dir := path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return cfg.save(path)


func has_token() -> bool:
	return not token.is_empty()


## Resolves the display name: preferred (when valid) wins over the stored name,
## which wins over a generated "player-xxxx". The result is stored on this object.
func ensure_name(preferred: String = "") -> String:
	var candidate := preferred.strip_edges()
	if candidate.length() > ClientHello.NAME_MAX:
		candidate = candidate.substr(0, ClientHello.NAME_MAX)
	if ClientHello.is_valid_name(candidate):
		name = candidate
	elif not ClientHello.is_valid_name(name):
		name = random_name()
	return name


## "player-" followed by four hex digits.
static func random_name() -> String:
	return "%s%04x" % [NAME_PREFIX, randi() % 0x10000]


## The first message after the transport connects. An empty token asks for a new player.
func hello() -> ClientHello:
	var message := ClientHello.new()
	message.token = token
	message.name = ensure_name(name)
	message.protocol = SliceConstants.PROTOCOL_VERSION
	return message


## Stores the token (and the server's view of the name) from WELCOME and saves.
func accept_welcome(welcome: ServerWelcome) -> Error:
	if welcome == null:
		return ERR_INVALID_PARAMETER
	if not welcome.token.is_empty():
		token = welcome.token
	if ClientHello.is_valid_name(welcome.name):
		name = welcome.name
	return save()


## Removes the file. Used by tests; a later load() then reports false.
func clear() -> Error:
	token = ""
	name = ""
	var absolute := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute):
		return OK
	return DirAccess.remove_absolute(absolute)

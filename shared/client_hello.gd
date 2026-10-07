class_name ClientHello
extends RefCounted

## First message a client sends after the transport connects, via RPC hello_rpc(dict).
## token is empty on a first visit; the server then issues one in ServerWelcome.
## A known token restores that player; an unknown token is treated as a new player.
## Commands sent before the server answers with WELCOME are rejected NOT_AUTHENTICATED.

const NAME_MIN := 1
const NAME_MAX := 24

var token: String = ""
## Display name, NAME_MIN..NAME_MAX characters.
var name: String = ""
var protocol: int = SliceConstants.PROTOCOL_VERSION


## True when p_name has NAME_MIN..NAME_MAX characters (Unicode code points).
static func is_valid_name(p_name: String) -> bool:
	var count := p_name.length()
	return count >= NAME_MIN and count <= NAME_MAX


func to_dict() -> Dictionary:
	return {
		"token": token,
		"name": name,
		"protocol": protocol,
	}


static func from_dict(data: Dictionary) -> ClientHello:
	var hello := ClientHello.new()
	hello.token = str(data.get("token", ""))
	hello.name = str(data.get("name", ""))
	hello.protocol = int(data.get("protocol", SliceConstants.PROTOCOL_VERSION))
	return hello

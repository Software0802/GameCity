class_name ServerWelcome
extends RefCounted

## Server's answer to ClientHello, sent as ServerEvent.Kind.WELCOME. It is the first
## event a connection receives. token is the issued (or confirmed) identity token;
## the client stores it locally. returning is true when the token matched a known player.

var token: String = ""
var player_id: int = -1
## SliceConstants.Owner. FACTION_A or FACTION_B.
var faction: int = SliceConstants.Owner.NEUTRAL
var name: String = ""
var returning: bool = false


func to_dict() -> Dictionary:
	return {
		"token": token,
		"player_id": player_id,
		"faction": faction,
		"name": name,
		"returning": returning,
	}


static func from_dict(data: Dictionary) -> ServerWelcome:
	var welcome := ServerWelcome.new()
	welcome.token = str(data.get("token", ""))
	welcome.player_id = int(data.get("player_id", -1))
	welcome.faction = int(data.get("faction", SliceConstants.Owner.NEUTRAL))
	welcome.name = str(data.get("name", ""))
	welcome.returning = bool(data.get("returning", false))
	return welcome

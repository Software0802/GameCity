class_name MatchStart
extends RefCounted

## Round is running. Commands are accepted only after this message.
## Map values echo the locked slice constants so a peer can see the map it joined.
## Clock values are wall-clock unix seconds; round_ends_at_unix is fixed when the
## round first starts and survives server restarts.

var map_size: int = SliceConstants.MAP_SIZE
var interest_block: int = SliceConstants.INTEREST_BLOCK
var faction_count: int = SliceConstants.FACTION_COUNT
var round_seconds: int = SliceConstants.ROUND_SECONDS_DEFAULT
var round_ends_at_unix: int = 0
## Server wall clock when this message was built; lets the client offset its own clock.
var server_unix: int = 0
var pace: float = SliceConstants.PACE_DEFAULT


func to_dict() -> Dictionary:
	return {
		"map_size": map_size,
		"interest_block": interest_block,
		"faction_count": faction_count,
		"round_seconds": round_seconds,
		"round_ends_at_unix": round_ends_at_unix,
		"server_unix": server_unix,
		"pace": pace,
	}


static func from_dict(data: Dictionary) -> MatchStart:
	var message := MatchStart.new()
	message.map_size = int(data.get("map_size", SliceConstants.MAP_SIZE))
	message.interest_block = int(data.get("interest_block", SliceConstants.INTEREST_BLOCK))
	message.faction_count = int(data.get("faction_count", SliceConstants.FACTION_COUNT))
	message.round_seconds = int(data.get("round_seconds", SliceConstants.ROUND_SECONDS_DEFAULT))
	message.round_ends_at_unix = int(data.get("round_ends_at_unix", 0))
	message.server_unix = int(data.get("server_unix", 0))
	message.pace = float(data.get("pace", SliceConstants.PACE_DEFAULT))
	return message

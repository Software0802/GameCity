class_name MatchStart
extends RefCounted

## Match has started. Commands are accepted only after this message.
## Values echo the locked slice constants so a peer can see the map it joined.

var map_size: int = SliceConstants.MAP_SIZE
var interest_block: int = SliceConstants.INTEREST_BLOCK
var faction_count: int = SliceConstants.FACTION_COUNT


func to_dict() -> Dictionary:
	return {
		"map_size": map_size,
		"interest_block": interest_block,
		"faction_count": faction_count,
	}


static func from_dict(data: Dictionary) -> MatchStart:
	var message := MatchStart.new()
	message.map_size = int(data.get("map_size", SliceConstants.MAP_SIZE))
	message.interest_block = int(data.get("interest_block", SliceConstants.INTEREST_BLOCK))
	message.faction_count = int(data.get("faction_count", SliceConstants.FACTION_COUNT))
	return message

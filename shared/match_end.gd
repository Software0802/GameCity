class_name MatchEnd
extends RefCounted

## Match is over. winner is SliceConstants.Owner.
## NEUTRAL means no faction won (host drop ends the match without a winner).

var winner: int = SliceConstants.Owner.NEUTRAL
var reason: String = ""


func to_dict() -> Dictionary:
	return {
		"winner": winner,
		"reason": reason,
	}


static func from_dict(data: Dictionary) -> MatchEnd:
	var message := MatchEnd.new()
	message.winner = int(data.get("winner", SliceConstants.Owner.NEUTRAL))
	message.reason = str(data.get("reason", ""))
	return message

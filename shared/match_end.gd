class_name MatchEnd
extends RefCounted

## Round is over. winner is SliceConstants.Owner; NEUTRAL means no faction won
## (a server stop ends the round without a winner).
## reason is REASON_CLOCK or REASON_SERVER_STOP. final_scores is the last ScoreTick
## and may be null (it is written as {} on the wire).

const REASON_CLOCK := "clock"
const REASON_SERVER_STOP := "server_stop"

var winner: int = SliceConstants.Owner.NEUTRAL
var reason: String = ""
var final_scores: ScoreTick = null


func to_dict() -> Dictionary:
	var scores: Dictionary = {}
	if final_scores != null:
		scores = final_scores.to_dict()
	return {
		"winner": winner,
		"reason": reason,
		"final_scores": scores,
	}


static func from_dict(data: Dictionary) -> MatchEnd:
	var message := MatchEnd.new()
	message.winner = int(data.get("winner", SliceConstants.Owner.NEUTRAL))
	message.reason = str(data.get("reason", ""))
	var raw_scores = data.get("final_scores", {})
	if raw_scores is Dictionary and not raw_scores.is_empty():
		message.final_scores = ScoreTick.from_dict(raw_scores)
	return message

class_name RegionSummary
extends RefCounted

## Coarse view of an interest region this client is not subscribed to.
## Not a per-tile or per-edge authority stream. Counts and flags are placeholders.

var interest: InterestId = null
var population: int = 0
var power_alert: bool = false
var crisis: bool = false


func to_dict() -> Dictionary:
	var interest_body: Dictionary = {}
	if interest != null:
		interest_body = interest.to_dict()
	return {
		"interest": interest_body,
		"population": population,
		"power_alert": power_alert,
		"crisis": crisis,
	}


static func from_dict(data: Dictionary) -> RegionSummary:
	var summary := RegionSummary.new()
	var raw_interest = data.get("interest", {})
	if raw_interest is Dictionary and not raw_interest.is_empty():
		summary.interest = InterestId.from_dict(raw_interest)
	elif raw_interest is int or raw_interest is String:
		summary.interest = InterestId.from_any(raw_interest)
	summary.population = int(data.get("population", 0))
	summary.power_alert = bool(data.get("power_alert", false))
	summary.crisis = bool(data.get("crisis", false))
	return summary

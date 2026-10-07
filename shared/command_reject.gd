class_name CommandReject
extends RefCounted

## Server rejected one client command. The client rolls back optimistic UI.
## kind mirrors the command when the body parsed; it can stand alone when it did not.
## reason is ReasonCode.Id. detail is optional.

var kind: int = -1
var command: GameCommand = null
var reason: int = ReasonCode.Id.NOT_IMPLEMENTED
var detail: String = ""


func _init(
	p_command: GameCommand = null,
	p_reason: int = ReasonCode.Id.NOT_IMPLEMENTED,
	p_detail: String = ""
) -> void:
	command = p_command
	reason = p_reason
	detail = p_detail
	if p_command != null:
		kind = p_command.kind


func to_dict() -> Dictionary:
	var body: Dictionary = {}
	if command != null:
		body = command.to_dict()
	return {
		"kind": kind,
		"reason": reason,
		"detail": detail,
		"command": body,
	}


static func from_dict(data: Dictionary) -> CommandReject:
	var reject := CommandReject.new()
	reject.reason = int(data.get("reason", ReasonCode.Id.NOT_IMPLEMENTED))
	reject.detail = str(data.get("detail", ""))
	var raw_command = data.get("command", {})
	if raw_command is Dictionary and not raw_command.is_empty():
		reject.command = GameCommand.from_dict(raw_command)
	if data.has("kind"):
		reject.kind = int(data["kind"])
	elif reject.command != null:
		reject.kind = reject.command.kind
	return reject

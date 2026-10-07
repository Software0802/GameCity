class_name LaunchArgs
extends RefCounted

## Reads the user arguments after "--" on the command line. The client does not
## depend on GameNet's static helpers for this so the autoload can change shape
## without breaking the client's launch path.
##   godot --path . -- --join 127.0.0.1 --port 24567 --name alice


static func has(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag)


## Value following flag, or fallback when the flag is absent or followed by another flag.
static func value(flag: String, fallback: String = "") -> String:
	var args := OS.get_cmdline_user_args()
	var idx := args.find(flag)
	if idx == -1 or idx + 1 >= args.size():
		return fallback
	var raw := str(args[idx + 1])
	if raw.begins_with("--"):
		return fallback
	return raw


static func int_value(flag: String, fallback: int) -> int:
	var raw := value(flag, "")
	if raw.is_empty() or not raw.is_valid_int():
		return fallback
	return int(raw)

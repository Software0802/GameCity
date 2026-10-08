class_name ClientSettings
extends RefCounted

## Local client preferences that are not part of the identity: today only whether the
## opening guide (client/ui/start_guide.gd) was closed. Stored next to the identity file
## so two clients with their own --identity files keep their own settings:
##   user://identity.cfg      -> user://settings.cfg
##   .demo/identity-A.cfg     -> .demo/settings-A.cfg
##   user://identity_stub.cfg -> user://settings_stub.cfg
## --settings <path> overrides the derived path.
##
## [guide]
## dismissed=true      the guide was closed or completed; it is not shown again

const DEFAULT_PATH := "user://settings.cfg"
const SECTION_GUIDE := "guide"

var path: String = DEFAULT_PATH
var guide_dismissed: bool = false


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path


## True when the file existed and parsed. A missing file keeps the defaults.
func load() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return false
	guide_dismissed = bool(cfg.get_value(SECTION_GUIDE, "dismissed", false))
	return true


func save() -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION_GUIDE, "dismissed", guide_dismissed)
	var dir := path.get_base_dir()
	if not dir.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	return cfg.save(path)


## Removes the file and resets the values. A later load() then reports false.
func clear() -> Error:
	guide_dismissed = false
	var absolute := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute):
		return OK
	return DirAccess.remove_absolute(absolute)


## Settings file beside an identity file: "identity" in the file name becomes "settings"
## ("identity-A.cfg" -> "settings-A.cfg"); any other name gets "-settings" appended.
static func path_for_identity(identity_path: String) -> String:
	var dir := identity_path.get_base_dir()
	var base := identity_path.get_file().get_basename()
	var ext := identity_path.get_extension()
	if ext.is_empty():
		ext = "cfg"
	var name := ""
	if base.find("identity") != -1:
		name = base.replace("identity", "settings")
	else:
		name = base + "-settings"
	if dir.is_empty():
		return "%s.%s" % [name, ext]
	return dir.path_join("%s.%s" % [name, ext])

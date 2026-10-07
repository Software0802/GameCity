extends RefCounted
## Shot table. Game cameras are orthographic, tilted `tilt` degrees from vertical (micro-oblique, brief: 15-30).
## Cinematic cameras are perspective with free placement and optional depth of field.

const Cfg := preload("res://client/assets/techart/showcase_max/scripts/cfg.gd")

## Tile coordinates -> world metres helper (tile centre).
static func tc(x: float, z: float) -> Vector3:
	return Vector3((x - Cfg.N * 0.5) * Cfg.P, 0.0, (z - Cfg.N * 0.5) * Cfg.P)

const ORDER := [
	"s01_hero_day", "s01_hero_dusk", "s02_far", "s03_near_block",
	"s00_cinematic_day", "s00_cinematic_dusk",
]

static func table() -> Dictionary:
	return {
		"s01_hero_day": {"kind": "game", "preset": "day", "focus": tc(6.4, 9.6), "size": 215.0, "yaw": 28.0, "tilt": 25.0, "w": 1920, "h": 1080},
		"s01_hero_dusk": {"kind": "game", "preset": "dusk", "focus": tc(6.4, 9.6), "size": 215.0, "yaw": 28.0, "tilt": 25.0, "w": 1920, "h": 1080},
		"s02_far": {"kind": "game", "preset": "day", "focus": tc(9.0, 8.6), "size": 540.0, "grid": true, "yaw": 0.0, "tilt": 25.0, "w": 1920, "h": 1080},
		"s03_near_block": {"kind": "game", "preset": "day", "focus": tc(6.0, 9.0), "size": 66.0, "yaw": 28.0, "tilt": 25.0, "w": 1920, "h": 1080},
		"s00_cinematic_day": {"kind": "cine", "preset": "day", "pos": tc(11.6, 12.6) + Vector3(0, 46.0, 0), "look": tc(6.2, 8.8) + Vector3(0, 26.0, 0), "fov": 36.0, "dof": true, "w": 1920, "h": 1080},
		"s00_cinematic_dusk": {"kind": "cine", "preset": "dusk", "pos": tc(11.6, 12.6) + Vector3(0, 46.0, 0), "look": tc(6.2, 8.8) + Vector3(0, 26.0, 0), "fov": 36.0, "dof": true, "w": 1920, "h": 1080},
	}

const GAME_DIST := 420.0

static func make_camera(shot: Dictionary, cam: Camera3D) -> void:
	if shot["kind"] == "game":
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = shot["size"]
		# camera looks down, tilted `tilt` degrees from vertical, yawed around Y
		var pitch := -(90.0 - float(shot["tilt"]))
		var basis := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(float(shot["yaw"])), 0.0), EULER_ORDER_YXZ)
		var back := basis.z
		cam.transform = Transform3D(basis, shot["focus"] + back * GAME_DIST)
		cam.near = GAME_DIST - 260.0
		cam.far = GAME_DIST + 260.0
	else:
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.fov = shot["fov"]
		cam.near = 0.2
		cam.far = 1800.0
		cam.transform = Transform3D(Basis.IDENTITY, shot["pos"])
		cam.look_at(shot["look"], Vector3.UP)

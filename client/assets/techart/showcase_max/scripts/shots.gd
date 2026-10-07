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
		"s01_hero_day": {"kind": "game", "preset": "day", "focus": tc(6.4, 9.6), "size": 215.0, "dist": 150.0, "sdfgi_cell": 0.9, "voxel_extent": 440.0, "yaw": 28.0, "tilt": 25.0, "w": 1920, "h": 1080},
		"s01_hero_dusk": {"kind": "game", "preset": "dusk", "focus": tc(6.4, 9.6), "size": 215.0, "dist": 150.0, "sdfgi_cell": 0.9, "voxel_extent": 440.0, "yaw": 28.0, "tilt": 25.0, "w": 1920, "h": 1080},
		"s02_far": {"kind": "game", "preset": "day", "focus": tc(9.0, 8.6), "size": 540.0, "dist": 260.0, "sdfgi_cell": 2.0, "voxel_extent": 1100.0, "voxel_subdiv": 256, "grid": true, "yaw": 0.0, "tilt": 25.0, "w": 1920, "h": 1080},
		"s03_near_block": {"kind": "game", "preset": "day", "focus": tc(3.6, 11.2), "size": 86.0, "dist": 110.0, "sdfgi_cell": 0.5, "voxel_extent": 300.0, "yaw": 28.0, "tilt": 25.0, "w": 1920, "h": 1080},
		"s03_near_block_dusk": {"kind": "game", "preset": "dusk", "focus": tc(3.6, 11.2), "size": 86.0, "dist": 110.0, "sdfgi_cell": 0.5, "voxel_extent": 300.0, "yaw": 28.0, "tilt": 25.0, "w": 1920, "h": 1080},
		"dev_lot": {"kind": "game", "preset": "day", "focus": tc(6.0, 9.0), "size": 40.0, "dist": 100.0, "sdfgi_cell": 0.5, "voxel_extent": 240.0, "yaw": 0.0, "tilt": 8.0, "w": 1920, "h": 1080},
		"dev_street_day": {"kind": "cine", "preset": "day", "pos": tc(5.0, 11.6) + Vector3(0, 2.3, 0), "look": tc(5.0, 7.0) + Vector3(0, 9.0, 0), "fov": 62.0, "voxel_extent": 300.0, "voxel_center": tc(5.0, 9.0), "w": 1920, "h": 1080},
		"dev_street_dusk": {"kind": "cine", "preset": "dusk", "pos": tc(5.0, 11.6) + Vector3(0, 2.3, 0), "look": tc(5.0, 7.0) + Vector3(0, 9.0, 0), "fov": 62.0, "voxel_extent": 300.0, "voxel_center": tc(5.0, 9.0), "w": 1920, "h": 1080},
		"dev_facade_r": {"kind": "cine", "preset": "day", "pos": tc(3.5, 9.4) + Vector3(0, 9.0, 0), "look": tc(3.5, 7.5) + Vector3(0, 12.0, 0), "fov": 48.0, "voxel_extent": 240.0, "voxel_center": tc(4.0, 8.0), "w": 1920, "h": 1080},
		"dev_facade_c": {"kind": "cine", "preset": "day", "pos": tc(14.2, 10.0) + Vector3(0, 12.0, 0), "look": tc(13.4, 7.0) + Vector3(0, 13.0, 0), "fov": 48.0, "voxel_extent": 240.0, "voxel_center": tc(6.0, 8.0), "w": 1920, "h": 1080},
		"s00_cinematic_day": {"kind": "cine", "preset": "day", "pos": tc(11.6, 12.6) + Vector3(0, 46.0, 0), "look": tc(6.2, 8.8) + Vector3(0, 26.0, 0), "fov": 36.0, "dof": true, "sdfgi_cell": 0.7, "voxel_extent": 480.0, "voxel_center": tc(8.0, 9.0), "w": 1920, "h": 1080},
		"s00_cinematic_dusk": {"kind": "cine", "preset": "dusk", "pos": tc(11.6, 12.6) + Vector3(0, 46.0, 0), "look": tc(6.2, 8.8) + Vector3(0, 26.0, 0), "fov": 36.0, "dof": true, "sdfgi_cell": 0.7, "voxel_extent": 480.0, "voxel_center": tc(8.0, 9.0), "w": 1920, "h": 1080},
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
		var dist: float = float(shot.get("dist", GAME_DIST))
		var half_depth: float = float(shot["size"]) * 0.23 + 78.0
		cam.transform = Transform3D(basis, shot["focus"] + back * dist)
		cam.near = maxf(0.5, dist - half_depth)
		cam.far = dist + half_depth + 90.0
	else:
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.fov = shot["fov"]
		cam.near = 0.2
		cam.far = 7000.0
		cam.transform = Transform3D(Basis.IDENTITY, shot["pos"])
		cam.look_at(shot["look"], Vector3.UP)

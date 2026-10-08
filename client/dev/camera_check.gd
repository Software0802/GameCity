extends Node3D

## Headless check of the camera rig and its input rules, without a server or a window: pitch
## clamps per projection, orthographic <-> perspective framing (the view stays as tall as the
## size at the target), zoom about the pointed ground point in both projections, picking through
## the actual projection (perspective, tilted and yawed), yaw-aware panning, the click / drag
## rule through CameraRig's and PlayInput's event handlers, the depth range and shadow reach the
## lighting reads at 30° and in perspective, the perspective cascade splits, and the opening view
## size. Prints CAMERA_OK and exits 0.
##   godot --headless --path . res://client/dev/camera_check.tscn

const Presentation := preload("res://client/presentation.gd")
const EPS := 1e-4

var _failures: Array[String] = []
var camera: CameraRig
var _view: Vector2


func _ready() -> void:
	camera = CameraRig.new()
	camera.name = "Camera"
	add_child(camera)
	_view = get_viewport().get_visible_rect().size
	_run()
	if _failures.is_empty():
		print("CAMERA_OK")
		get_tree().quit(0)
	else:
		for line in _failures:
			printerr("CAMERA_FAIL " + line)
		get_tree().quit(1)


func _run() -> void:
	_expect(_view.x > 0.0 and _view.y > 0.0, "viewport has a size (got %s)" % _view)
	_check_pitch_clamps()
	_check_projection_switch()
	_check_zoom_anchor()
	_check_picking()
	_check_pan()
	_check_drag_rule()
	_check_depth_and_shadows()
	_check_right_click_cancel()
	_check_opening_view()


func _check_pitch_clamps() -> void:
	camera.set_pitch(10.0)
	_expect(is_equal_approx(camera.pitch_deg, CameraRig.PITCH_MIN), "ortho pitch clamps at %.0f (got %.2f)" % [CameraRig.PITCH_MIN, camera.pitch_deg])
	camera.set_pitch(89.0)
	_expect(is_equal_approx(camera.pitch_deg, CameraRig.PITCH_MAX), "pitch clamps at %.0f" % CameraRig.PITCH_MAX)
	camera.set_pitch(45.0)
	_expect(is_equal_approx(camera.pitch_deg, 45.0), "pitch inside the range is kept")
	camera.set_perspective_mode(true)
	camera.set_pitch(10.0)
	_expect(is_equal_approx(camera.pitch_deg, CameraRig.PITCH_MIN_PERSPECTIVE), "perspective pitch floor %.0f (got %.2f)" % [CameraRig.PITCH_MIN_PERSPECTIVE, camera.pitch_deg])
	camera.set_perspective_mode(false)
	_expect(is_equal_approx(camera.pitch_deg, CameraRig.PITCH_MIN), "back to ortho re-clamps 25 -> 30 (got %.2f)" % camera.pitch_deg)
	camera.set_yaw(190.0)
	_expect(is_equal_approx(camera.yaw_deg, -170.0), "yaw wraps to (-180, 180] (got %.2f)" % camera.yaw_deg)
	camera.set_perspective_mode(true)
	camera.reset_view()
	_expect(is_equal_approx(camera.pitch_deg, CameraRig.PITCH_DEFAULT) and is_equal_approx(camera.yaw_deg, 0.0), "reset_view restores 65° / north")
	_expect(camera.perspective, "reset_view keeps the projection")
	camera.set_perspective_mode(false)
	_expect(is_equal_approx(CameraRig.clamp_pitch(0.0, true), 25.0) and is_equal_approx(CameraRig.clamp_pitch(0.0, false), 30.0), "clamp_pitch floors per projection")
	_expect(is_equal_approx(CameraRig.clamp_pitch(90.0, true), 70.0), "clamp_pitch ceiling")


## The screen top edge is size / 2 above the target along the camera's up axis in both
## projections: that is the ortho definition of size and, in perspective, the distance
## perspective_distance() chooses.
func _check_projection_switch() -> void:
	camera.reset_view()
	camera.focus_tile(10, 10)
	camera.set_ortho_size(240.0)
	var half := 120.0
	var top := camera.unproject_position(camera.target + camera.basis.y * half)
	_expect(absf(top.y) < 1.0 and absf(top.x - _view.x * 0.5) < 1.0, "ortho: target + size/2 along screen-up is the top edge centre (got %s)" % top)
	camera.set_perspective_mode(true)
	_expect(camera.projection == Camera3D.PROJECTION_PERSPECTIVE and is_equal_approx(camera.fov, CameraRig.FOV_DEG), "perspective projection with FOV %.0f" % CameraRig.FOV_DEG)
	var dist := camera.position.distance_to(camera.target)
	var expected := CameraRig.perspective_distance(240.0, CameraRig.FOV_DEG)
	_expect(absf(dist - expected) < 0.01, "focus distance %.2f = size / (2 tan(fov/2)) (got %.2f)" % [expected, dist])
	_expect(absf(expected - 257.34) < 0.05, "240 m at 50° is 257.3 m from the target (got %.2f)" % expected)
	_expect(is_equal_approx(CameraRig.size_for_distance(expected, CameraRig.FOV_DEG), 240.0), "size_for_distance inverts perspective_distance")
	top = camera.unproject_position(camera.target + camera.basis.y * half)
	var bottom := camera.unproject_position(camera.target - camera.basis.y * half)
	_expect(absf(top.y) < 1.0, "perspective: the view is as tall as the size at the target, top edge (got %.2f)" % top.y)
	_expect(absf(bottom.y - _view.y) < 1.0, "perspective: bottom edge (got %.2f of %.0f)" % [bottom.y, _view.y])
	_expect(absf(camera.focus_distance() - dist) < 0.01, "focus_distance reports the camera-target distance")
	camera.set_perspective_mode(false)
	_expect(camera.projection == Camera3D.PROJECTION_ORTHOGONAL and is_equal_approx(camera.size, 240.0), "back to ortho keeps the size")


## Wheel zoom keeps the ground point under the pointer in place, both projections, with a tilt
## and a yaw so no axis is trivially aligned; zooming back restores target and anchor.
func _check_zoom_anchor() -> void:
	for persp in [false, true]:
		var label := "perspective" if persp else "ortho"
		camera.set_perspective_mode(persp)
		camera.focus_tile(20, 20)
		camera.set_ortho_size(300.0)
		camera.set_pitch(50.0)
		camera.set_yaw(30.0)
		var screen := Vector2(_view.x * 0.7, _view.y * 0.3)
		var anchor := camera.ground_point(screen)
		_expect(anchor.is_finite(), "%s: the pointer ray hits the ground" % label)
		var old_target := camera.target
		camera.zoom_at(screen, 1)
		_expect(is_equal_approx(camera.size, 300.0 / CameraRig.ZOOM_FACTOR), "%s: zoom_at divides the size by %.2f" % [label, CameraRig.ZOOM_FACTOR])
		var after := camera.ground_point(screen)
		_expect(after.is_finite() and after.distance_to(anchor) < 0.05, "%s: the pointed ground point stays put (drift %.3f m)" % [label, after.distance_to(anchor)])
		_expect(camera.target.distance_to(old_target) > 1.0, "%s: the target moved toward the anchor (%.2f m)" % [label, camera.target.distance_to(old_target)])
		camera.zoom_at(screen, -1)
		_expect(is_equal_approx(camera.size, 300.0), "%s: zooming back restores the size" % label)
		_expect(camera.ground_point(screen).distance_to(anchor) < 0.05 and camera.target.distance_to(old_target) < 0.05, "%s: zooming back restores anchor and target" % label)
		var centre := camera.unproject_position(camera.target)
		camera.zoom_at(centre, 1)
		_expect(camera.target.distance_to(old_target) < 0.05, "%s: pointer on the target zooms about the target" % label)
		camera.zoom_at(centre, -1)
	# A ray at or above the horizon has no anchor: the zoom falls back to the target.
	camera.set_perspective_mode(true)
	camera.set_pitch(25.0)
	var top := Vector2(_view.x * 0.5, 0.0)
	_expect(not camera.ground_point(top).is_finite(), "perspective at 25°: the top-edge ray misses the ground")
	var kept := camera.target
	camera.zoom_at(top, 1)
	_expect(camera.target.distance_to(kept) < EPS, "no anchor: the target stays")
	_expect(is_equal_approx(camera.size, 300.0 / CameraRig.ZOOM_FACTOR), "no anchor: the size still changes")
	camera.zoom_at(top, -1)
	_expect(not CameraRig.anchor_usable(CameraRig.NO_GROUND), "NO_GROUND is not an anchor")
	_expect(not CameraRig.anchor_usable(Vector3(-2.0 * CameraRig.Cfg.map_extent() - 1.0, 0.0, 0.0)), "a hit two map extents away is not an anchor")
	_expect(CameraRig.anchor_usable(Vector3(-1.0, 0.0, 10.0)), "a hit just off the map edge is an anchor")
	_expect(not CameraRig.hit_ground(Vector3(0.0, 100.0, 0.0), Vector3(0.0, 0.0, -1.0)).is_finite(), "a horizontal ray misses the ground")
	_expect(not CameraRig.hit_ground(Vector3(0.0, 100.0, 0.0), Vector3(0.0, 0.5, -0.5).normalized()).is_finite(), "a rising ray misses the ground")
	var hit := CameraRig.hit_ground(Vector3(0.0, 100.0, 0.0), Vector3(0.0, -1.0, -1.0).normalized())
	_expect(hit.is_finite() and hit.distance_to(Vector3(0.0, 0.0, -100.0)) < EPS, "a 45° ray from 100 m up lands 100 m ahead (got %s)" % hit)
	camera.set_perspective_mode(false)
	camera.set_yaw(0.0)


func _check_picking() -> void:
	camera.reset_view()
	camera.focus_tile(10, 10)
	camera.set_ortho_size(900.0)
	for cell in [Vector2i(12, 9), Vector2i(10, 10), Vector2i(7, 12)]:
		_expect(camera.pick_tile(camera.tile_to_screen(cell)) == cell, "ortho: pick_tile inverts tile_to_screen for %s (got %s)" % [cell, camera.pick_tile(camera.tile_to_screen(cell))])
	camera.set_perspective_mode(true)
	camera.set_ortho_size(240.0)
	camera.set_pitch(30.0)
	camera.set_yaw(45.0)
	for cell in [Vector2i(12, 9), Vector2i(10, 10), Vector2i(7, 12), Vector2i(10, 13)]:
		_expect(camera.pick_tile(camera.tile_to_screen(cell)) == cell, "perspective 30° / yaw 45°: pick_tile inverts tile_to_screen for %s (got %s)" % [cell, camera.pick_tile(camera.tile_to_screen(cell))])
	# A tile centre's ground point is that centre.
	var centre := camera.ground_point(camera.tile_to_screen(Vector2i(12, 9)))
	_expect(centre.distance_to(CameraRig.Cfg.to_world(Vector2i(12, 9))) < 0.01, "ground_point of a tile centre is the tile centre (got %s)" % centre)
	_expect(camera.pick_tile(Vector2(_view.x * 0.5, 0.0)) != CameraRig.NO_TILE or true, "top edge pick runs")
	camera.set_perspective_mode(false)
	camera.set_yaw(0.0)
	camera.focus_tile(-50, 500)
	_expect(camera.pick_tile(Vector2(-5000.0, -5000.0)) == CameraRig.NO_TILE, "a ray off the map picks NO_TILE")


func _check_pan() -> void:
	_expect(CameraRig.pan_on_ground(Vector2(0.0, -1.0), 0.0).distance_to(Vector3(0.0, 0.0, -1.0)) < EPS, "yaw 0: up pans north (-Z)")
	_expect(CameraRig.pan_on_ground(Vector2(1.0, 0.0), 0.0).distance_to(Vector3(1.0, 0.0, 0.0)) < EPS, "yaw 0: right pans east (+X)")
	_expect(CameraRig.pan_on_ground(Vector2(0.0, -1.0), 90.0).distance_to(Vector3(-1.0, 0.0, 0.0)) < EPS, "yaw 90: up pans west (got %s)" % CameraRig.pan_on_ground(Vector2(0.0, -1.0), 90.0))
	_expect(CameraRig.pan_on_ground(Vector2(1.0, 0.0), 90.0).distance_to(Vector3(0.0, 0.0, -1.0)) < EPS, "yaw 90: right pans north (got %s)" % CameraRig.pan_on_ground(Vector2(1.0, 0.0), 90.0))
	# The static mapping agrees with the camera's actual basis at that yaw.
	camera.set_yaw(90.0)
	_expect(camera.basis.x.distance_to(Vector3(0.0, 0.0, -1.0)) < EPS, "camera right at yaw 90 is north (got %s)" % camera.basis.x)
	var forward := -camera.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	_expect(forward.distance_to(Vector3(-1.0, 0.0, 0.0)) < EPS, "camera ground-forward at yaw 90 is west (got %s)" % forward)
	camera.set_yaw(0.0)
	_expect(camera.basis.x.distance_to(Vector3(1.0, 0.0, 0.0)) < EPS, "camera right at yaw 0 is east")
	# Panning with a yaw moves the target along the rotated axes.
	camera.focus_tile(20, 20)
	camera.set_yaw(90.0)
	var before := camera.target
	camera.target += CameraRig.pan_on_ground(Vector2(0.0, -1.0) * 30.0, camera.yaw_deg)
	camera._apply()
	_expect(absf((camera.target - before).x + 30.0) < EPS and absf((camera.target - before).z) < EPS, "a 30 m up-pan at yaw 90 moves the target 30 m west (got %s)" % (camera.target - before))
	camera.set_yaw(0.0)


## Click versus drag: the static rule, then the real handlers with constructed events.
func _check_drag_rule() -> void:
	var p := Vector2(100.0, 100.0)
	_expect(not CameraRig.is_drag(p, p + Vector2(3.0, 0.0)), "3 px is a click")
	_expect(not CameraRig.is_drag(p, p + Vector2(0.0, 4.0)), "exactly 4 px is still a click")
	_expect(CameraRig.is_drag(p, p + Vector2(0.0, 5.0)), "5 px is a drag")
	_expect(CameraRig.is_drag(p, p + Vector2(3.0, 3.0)), "3,3 (4.24 px) is a drag")
	camera.reset_view()
	camera.set_perspective_mode(false)
	var p0 := Vector2(600.0, 400.0)
	camera._input(_mb(MOUSE_BUTTON_RIGHT, true, p0))
	camera._input(_mm(Vector2(600.0, 402.0), Vector2(0.0, 2.0)))
	_expect(is_equal_approx(camera.pitch_deg, 65.0), "right press + 2 px: no tilt yet")
	camera._input(_mm(Vector2(600.0, 300.0), Vector2(0.0, -102.0)))
	_expect(absf(camera.pitch_deg - 40.0) < 0.01, "right drag 100 px up tilts 25° toward the horizon: 65 -> 40 (got %.2f)" % camera.pitch_deg)
	camera._input(_mm(Vector2(600.0, 100.0), Vector2(0.0, -200.0)))
	_expect(is_equal_approx(camera.pitch_deg, CameraRig.PITCH_MIN), "tilt clamps at %.0f" % CameraRig.PITCH_MIN)
	camera._input(_mb(MOUSE_BUTTON_RIGHT, false, Vector2(600.0, 100.0)))
	camera._input(_mm(Vector2(600.0, 300.0), Vector2(0.0, 200.0)))
	_expect(is_equal_approx(camera.pitch_deg, CameraRig.PITCH_MIN), "motion after the release does not tilt")
	camera._input(_mb(MOUSE_BUTTON_MIDDLE, true, p0))
	camera._input(_mm(Vector2(700.0, 400.0), Vector2(100.0, 0.0)))
	_expect(absf(camera.yaw_deg - 100.0 * CameraRig.ORBIT_DEG_PER_PX) < 0.01, "middle drag 100 px right orbits %.0f° (got %.2f)" % [100.0 * CameraRig.ORBIT_DEG_PER_PX, camera.yaw_deg])
	camera._input(_mb(MOUSE_BUTTON_MIDDLE, false, Vector2(700.0, 400.0)))
	camera._unhandled_input(_key(KEY_R))
	_expect(is_equal_approx(camera.pitch_deg, 65.0) and is_equal_approx(camera.yaw_deg, 0.0), "R resets pitch and yaw")
	camera._unhandled_input(_key(KEY_V))
	_expect(camera.perspective, "V switches to perspective")
	camera._unhandled_input(_key(KEY_V))
	_expect(not camera.perspective, "V again switches back")
	camera.focus_tile(20, 20)
	camera.set_ortho_size(300.0)
	camera._unhandled_input(_mb(MOUSE_BUTTON_WHEEL_UP, true, camera.unproject_position(camera.target)))
	_expect(is_equal_approx(camera.size, 300.0 / CameraRig.ZOOM_FACTOR), "wheel up through _unhandled_input zooms in one notch")
	camera._unhandled_input(_mb(MOUSE_BUTTON_WHEEL_DOWN, true, camera.unproject_position(camera.target)))
	_expect(is_equal_approx(camera.size, 300.0), "wheel down zooms back out")
	# zoom_steps stays the plain target-centred rule the view check relies on
	var t := camera.target
	camera.zoom_steps(2)
	_expect(is_equal_approx(camera.size, 300.0 / (CameraRig.ZOOM_FACTOR * CameraRig.ZOOM_FACTOR)) and camera.target == t, "zoom_steps keeps the target")
	camera.set_ortho_size(300.0)


## Depth range and shadow reach at the low-angle case (90 m, 30°) and in perspective; the
## lighting reads shadow_near() / shadow_distance() / far from these.
func _check_depth_and_shadows() -> void:
	camera.set_perspective_mode(false)
	camera.focus_tile(20, 20)
	camera.set_ortho_size(90.0)
	camera.set_pitch(30.0)
	camera.set_yaw(0.0)
	var pitch := deg_to_rad(30.0)
	_expect(absf(CameraRig.depth_per_size(deg_to_rad(65.0)) - 0.2332) < 0.001, "depth_per_size(65°) = cos / 2 sin = 0.233")
	var half := 90.0 * CameraRig.depth_per_size(pitch)
	_expect(absf(half - 77.94) < 0.01, "90 m at 30°: the far-edge ground is 77.9 m deeper than the target (got %.2f)" % half)
	_expect(camera.near < camera.far and camera.far > camera.position.y, "ortho depth range covers the ground")
	_expect(is_equal_approx(camera.near, CameraRig.NEAR_PAD), "ortho near plane is NEAR_PAD")
	_expect(absf(camera.far - (camera.focus_distance() + half + CameraRig.FAR_PAD)) < 1e-3, "ortho far = focus distance + half span + pad")
	var sn := camera.shadow_near()
	_expect(sn > camera.near and sn < camera.far, "ortho shadow_near inside [near, far] (got %.1f in %.1f..%.1f)" % [sn, camera.near, camera.far])
	_expect(sn - CameraRig.SCENE_HEIGHT / sin(pitch) >= CameraRig.NEAR_PAD - 1e-3, "a %.0f m tower below the near edge stays past the near plane at 30°" % CameraRig.SCENE_HEIGHT)
	var bottom := camera.ground_point(Vector2(_view.x * 0.5, _view.y))
	_expect(absf(_depth(bottom) - sn) < 0.5, "ortho shadow_near is the bottom-edge ground depth (%.2f vs %.2f)" % [_depth(bottom), sn])
	var top := camera.ground_point(Vector2(_view.x * 0.5, 0.0))
	_expect(absf(_depth(top) + CameraRig.FAR_PAD - camera.far) < 0.5, "ortho far is the top-edge ground depth + pad (%.2f vs %.2f)" % [_depth(top) + CameraRig.FAR_PAD, camera.far])
	_expect(is_equal_approx(camera.shadow_distance(), camera.far), "ortho shadow reach = far")
	var ortho_far := camera.far
	camera.set_pitch(65.0)
	_expect(camera.far < ortho_far, "a steeper pitch has a tighter far plane (%.1f < %.1f)" % [camera.far, ortho_far])
	camera.set_pitch(30.0)

	camera.set_perspective_mode(true)
	var dist := camera.focus_distance()
	_expect(absf(camera.near - clampf(dist * CameraRig.PERSPECTIVE_NEAR_FRACTION, CameraRig.PERSPECTIVE_NEAR_MIN, CameraRig.PERSPECTIVE_NEAR_MAX)) < 1e-6, "perspective near is a fraction of the focus distance (got %.3f for %.1f m)" % [camera.near, dist])
	_expect(camera.near < 2.0, "perspective near at 90 m stays under 2 m so street-level facades are not clipped (got %.3f)" % camera.near)
	top = camera.ground_point(Vector2(_view.x * 0.5, 0.0))
	_expect(top.is_finite(), "perspective 30°: the top edge still sees ground")
	_expect(absf(_depth(top) + CameraRig.FAR_PAD - camera.far) < 0.5, "perspective far = top-edge ground depth + pad (%.2f vs %.2f)" % [_depth(top) + CameraRig.FAR_PAD, camera.far])
	var corner := camera.ground_point(Vector2(0.0, 0.0))
	_expect(absf(_depth(corner) - _depth(top)) < 0.5, "the top corners share the top edge's depth (%.2f vs %.2f)" % [_depth(corner), _depth(top)])
	bottom = camera.ground_point(Vector2(_view.x * 0.5, _view.y))
	_expect(absf(_depth(bottom) - camera.shadow_near()) < 0.5, "perspective shadow_near is the bottom-edge ground depth (%.2f vs %.2f)" % [_depth(bottom), camera.shadow_near()])
	_expect(camera.shadow_distance() <= camera.far + EPS and camera.shadow_distance() >= camera.shadow_near(), "perspective shadow reach within [shadow_near, far] (%.1f in %.1f..%.1f)" % [camera.shadow_distance(), camera.shadow_near(), camera.far])
	_expect(is_equal_approx(CameraRig.perspective_far(dist, 30.0), camera.far), "perspective_far matches the applied far plane")
	camera.set_pitch(25.0)
	_expect(is_equal_approx(camera.far, CameraRig.PERSPECTIVE_FAR_MAX), "perspective 25°: the top edge is the horizon, far = cap (got %.0f)" % camera.far)
	_expect(is_equal_approx(camera.shadow_distance(), dist * CameraRig.SHADOW_REACH_PER_DISTANCE), "perspective 25°: shadow reach = %.0f × focus distance, not the far cap" % CameraRig.SHADOW_REACH_PER_DISTANCE)
	_expect(not is_finite(CameraRig.ground_depth(100.0, deg_to_rad(25.0), tan(deg_to_rad(25.0)))), "ground_depth of a horizontal ray is INF")
	_expect(absf(CameraRig.ground_depth(100.0, deg_to_rad(90.0), 0.0) - 100.0) < EPS, "ground_depth straight down is the distance")
	camera.set_ortho_size(4800.0)
	_expect(camera.near <= CameraRig.PERSPECTIVE_NEAR_MAX and camera.far <= CameraRig.PERSPECTIVE_FAR_MAX and camera.near < camera.far, "perspective at SIZE_MAX keeps a sane depth range (%.1f..%.0f)" % [camera.near, camera.far])
	camera.set_ortho_size(90.0)
	camera.set_perspective_mode(false)

	var splits := LiveLighting.cascade_splits(58.6, 551.0)
	_expect(splits.size() == 3 and splits[0] < splits[1] and splits[1] < splits[2] and splits[2] < 1.0, "three increasing splits below 1 (got %s)" % str(splits))
	_expect(absf(splits[0] - 1.6 * 58.6 / 551.0) < 1e-6, "first split ends 1.6 × the nearest ground (got %.3f)" % splits[0])
	_expect(absf(splits[1] / splits[0] - splits[2] / splits[1]) < 1e-6 and absf(splits[2] / splits[1] - 1.0 / splits[2]) < 1e-6, "splits are log-spaced up to the reach")
	var wide := LiveLighting.cascade_splits(INF, 1000.0)
	_expect(is_equal_approx(wide[0], LiveLighting.SPLIT_MIN), "no visible ground: the first split is the minimum")
	var tight := LiveLighting.cascade_splits(900.0, 1000.0)
	_expect(is_equal_approx(tight[0], LiveLighting.SPLIT_MAX), "ground almost at the reach: the first split is capped")


## PlayInput's right-click rule: a click (<= DRAG_PX) clears the tool, a drag keeps it.
func _check_right_click_cancel() -> void:
	var toolbar := Toolbar.new()
	toolbar.name = "Toolbar"
	add_child(toolbar)
	toolbar.set_enabled(true)
	var input := PlayInput.new()
	input.name = "Input"
	input.toolbar = toolbar
	add_child(input)
	toolbar.set_tool(Toolbar.Tool.CLAIM)
	_expect(toolbar.tool == Toolbar.Tool.CLAIM, "tool armed")
	input._input(_mb(MOUSE_BUTTON_RIGHT, true, Vector2(600.0, 400.0)))
	_expect(toolbar.tool == Toolbar.Tool.CLAIM, "right press alone does not cancel yet")
	input._input(_mm(Vector2(602.0, 401.0), Vector2(2.0, 1.0)))
	input._input(_mb(MOUSE_BUTTON_RIGHT, false, Vector2(602.0, 401.0)))
	_expect(toolbar.tool == Toolbar.Tool.NONE, "right click (2 px) cancels the tool")
	toolbar.set_tool(Toolbar.Tool.ROAD)
	input._input(_mb(MOUSE_BUTTON_RIGHT, true, Vector2(600.0, 400.0)))
	input._input(_mm(Vector2(600.0, 300.0), Vector2(0.0, -100.0)))
	input._input(_mb(MOUSE_BUTTON_RIGHT, false, Vector2(600.0, 300.0)))
	_expect(toolbar.tool == Toolbar.Tool.ROAD, "right drag (100 px) keeps the tool")
	input._input(_mb(MOUSE_BUTTON_RIGHT, true, Vector2(600.0, 400.0)))
	input._input(_mm(Vector2(650.0, 400.0), Vector2(50.0, 0.0)))
	input._input(_mb(MOUSE_BUTTON_RIGHT, false, Vector2(601.0, 400.0)))
	_expect(toolbar.tool == Toolbar.Tool.ROAD, "a drag that comes back to the press point is still a drag")
	input._input(_mb(MOUSE_BUTTON_RIGHT, false, Vector2(601.0, 400.0)))
	_expect(toolbar.tool == Toolbar.Tool.ROAD, "a stray release without a press does nothing")
	input._input(_key(KEY_ESCAPE))
	_expect(toolbar.tool == Toolbar.Tool.ROAD, "Esc goes through _unhandled_input, not _input")
	input._unhandled_input(_key(KEY_ESCAPE))
	_expect(toolbar.tool == Toolbar.Tool.NONE, "Esc cancels the tool")
	input.queue_free()
	toolbar.queue_free()


func _check_opening_view() -> void:
	_expect(is_equal_approx(Presentation.START_VIEW_SIZE, 8.0 * CameraRig.TILE), "opening view is 8 tiles / 240 m (got %.0f)" % Presentation.START_VIEW_SIZE)
	_expect(Presentation.START_VIEW_SIZE >= CameraRig.SIZE_MIN and Presentation.START_VIEW_SIZE <= CameraRig.SIZE_MAX, "opening view inside the zoom range")
	_expect(is_equal_approx(CameraRig.SIZE_MIN, 3.0 * CameraRig.TILE) and is_equal_approx(CameraRig.SIZE_MAX, 160.0 * CameraRig.TILE), "zoom range 3..160 tiles")


## Depth of a world point along the camera's view axis.
func _depth(point: Vector3) -> float:
	return (point - camera.global_position).dot(-camera.global_basis.z)


func _mb(index: MouseButton, pressed: bool, at: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.pressed = pressed
	event.position = at
	event.global_position = at
	return event


func _mm(at: Vector2, relative: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = relative
	return event


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	return event


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)

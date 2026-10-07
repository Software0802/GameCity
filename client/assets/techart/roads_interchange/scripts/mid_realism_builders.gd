extends RefCounted
class_name MidRealismBuilders
## Reusable mid-realism builders for roads_interchange pack.
## Materials: prefer loading .tres after editor import; CLI-safe ImageTexture fallback.
## Overlays (faction/power/congestion) stay separate — never bake into world albedo.

const PACK := "res://client/assets/techart/roads_interchange"

var mat_asphalt: StandardMaterial3D
var mat_concrete: StandardMaterial3D
var mat_grass: StandardMaterial3D
var mat_glass: StandardMaterial3D
var mat_frame: StandardMaterial3D
var mat_curb: StandardMaterial3D
var mat_decal: StandardMaterial3D
var mat_canopy: StandardMaterial3D
var mat_bark: StandardMaterial3D
var mat_v_dark: StandardMaterial3D
var mat_v_white: StandardMaterial3D
var mat_v_blue: StandardMaterial3D
var mat_v_glass: StandardMaterial3D
var mat_fa: StandardMaterial3D
var mat_fb: StandardMaterial3D
var mat_power: StandardMaterial3D
var mat_cong: StandardMaterial3D

func _tex(rel: String) -> Texture2D:
	var path := PACK + "/textures/" + rel
	var abs_path := ProjectSettings.globalize_path(path)
	var img := Image.new()
	var err := img.load(abs_path)
	if err != OK:
		push_error("texture load failed: " + abs_path + " err=" + str(err))
		return null
	return ImageTexture.create_from_image(img)

func _try_load_mat(rel: String) -> StandardMaterial3D:
	var path := PACK + "/materials/" + rel
	if ResourceLoader.exists(path):
		var m := load(path) as StandardMaterial3D
		if m != null:
			return m
	return null

func ensure_materials() -> void:
	## Build runtime materials (CLI-safe). Matches shipped .tres look.
	mat_asphalt = StandardMaterial3D.new()
	mat_asphalt.albedo_texture = _tex("asphalt_albedo.png")
	mat_asphalt.normal_enabled = true
	mat_asphalt.normal_texture = _tex("asphalt_normal.png")
	mat_asphalt.normal_scale = 0.85
	mat_asphalt.roughness_texture = _tex("asphalt_rough.png")
	mat_asphalt.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat_asphalt.roughness = 1.0
	mat_asphalt.metallic = 0.04
	mat_asphalt.uv1_scale = Vector3(6, 6, 6)
	mat_asphalt.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	mat_concrete = StandardMaterial3D.new()
	mat_concrete.albedo_texture = _tex("concrete_albedo.png")
	mat_concrete.normal_enabled = true
	mat_concrete.normal_texture = _tex("concrete_normal.png")
	mat_concrete.normal_scale = 0.55
	mat_concrete.roughness = 0.82
	mat_concrete.uv1_scale = Vector3(3, 3, 3)
	mat_concrete.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	mat_grass = StandardMaterial3D.new()
	mat_grass.albedo_texture = _tex("grass_albedo.png")
	mat_grass.roughness = 0.95
	mat_grass.uv1_scale = Vector3(14, 14, 14)
	mat_grass.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	mat_glass = StandardMaterial3D.new()
	mat_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_glass.albedo_color = Color(0.42, 0.58, 0.72, 0.42)
	mat_glass.albedo_texture = _tex("glass_tint.png")
	mat_glass.metallic = 0.95
	mat_glass.roughness = 0.045
	mat_glass.metallic_specular = 1.0
	mat_glass.refraction_enabled = true
	mat_glass.refraction_scale = 0.02
	mat_glass.clearcoat_enabled = true
	mat_glass.clearcoat = 0.35
	mat_glass.clearcoat_roughness = 0.05

	mat_frame = StandardMaterial3D.new()
	mat_frame.albedo_color = Color(0.28, 0.30, 0.33)
	mat_frame.metallic = 0.75
	mat_frame.roughness = 0.35

	mat_curb = StandardMaterial3D.new()
	mat_curb.albedo_texture = _tex("concrete_albedo.png")
	mat_curb.albedo_color = Color(0.78, 0.76, 0.72)
	mat_curb.roughness = 0.78
	mat_curb.uv1_scale = Vector3(2, 2, 2)

	mat_decal = StandardMaterial3D.new()
	mat_decal.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_decal.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat_decal.albedo_color = Color(1, 1, 1, 1)
	mat_decal.roughness = 0.55
	mat_decal.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat_decal.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	mat_canopy = StandardMaterial3D.new()
	mat_canopy.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat_canopy.alpha_scissor_threshold = 0.35
	mat_canopy.albedo_texture = _tex("tree_canopy.png")
	mat_canopy.roughness = 0.9
	mat_canopy.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat_canopy.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	mat_bark = StandardMaterial3D.new()
	mat_bark.albedo_texture = _tex("tree_bark.png")
	mat_bark.roughness = 0.92
	mat_bark.uv1_scale = Vector3(1, 3, 1)

	mat_v_dark = _car_paint(Color(0.12, 0.13, 0.15))
	mat_v_white = _car_paint(Color(0.86, 0.87, 0.89))
	mat_v_blue = _car_paint(Color(0.14, 0.32, 0.58))
	mat_v_glass = StandardMaterial3D.new()
	mat_v_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_v_glass.albedo_color = Color(0.55, 0.7, 0.85, 0.55)
	mat_v_glass.metallic = 0.9
	mat_v_glass.roughness = 0.08

	# Overlays — separate layer materials
	mat_fa = _try_load_mat("mat_faction_a.tres")
	if mat_fa == null:
		mat_fa = _emissive(Color(0.180392, 0.901961, 0.658824))
	mat_fb = _try_load_mat("mat_faction_b.tres")
	if mat_fb == null:
		mat_fb = _emissive(Color(1.0, 0.360784, 0.478431))
	mat_power = _try_load_mat("mat_service_power.tres")
	if mat_power == null:
		mat_power = _emissive(Color(0.960784, 0.843137, 0.431373))
	mat_cong = _try_load_mat("mat_road_congestion.tres")
	if mat_cong == null:
		mat_cong = _emissive(Color(0.941176, 0.788235, 0.227451))

func _car_paint(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = 0.65
	m.roughness = 0.28
	m.clearcoat_enabled = true
	m.clearcoat = 0.55
	m.clearcoat_roughness = 0.12
	return m

func _emissive(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.55
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 0.35
	return m

func mi(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material, rot := Vector3.ZERO, cast_shadow := true) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.mesh = mesh
	n.position = pos
	n.rotation = rot
	n.material_override = mat
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	parent.add_child(n)
	return n

func box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, yaw := 0.0, cast_shadow := true) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mi(parent, mesh, pos, mat, Vector3(0, yaw, 0), cast_shadow)

func cyl(parent: Node3D, r_top: float, r_bot: float, h: float, pos: Vector3, mat: Material, yaw := 0.0) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = r_top
	mesh.bottom_radius = r_bot
	mesh.height = h
	mesh.radial_segments = 16
	return mi(parent, mesh, pos, mat, Vector3(0, yaw, 0))

func decal_quad(parent: Node3D, tex_name: String, size: Vector2, pos: Vector3, yaw: float) -> void:
	var mat := mat_decal.duplicate() as StandardMaterial3D
	mat.albedo_texture = _tex(tex_name)
	var mesh := QuadMesh.new()
	mesh.size = size
	var n := mi(parent, mesh, pos, mat, Vector3(deg_to_rad(-90), yaw, 0), false)
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Ground arterial + curb + lane decals (world layer).
func build_ground_road(parent: Node3D) -> void:
	box(parent, Vector3(52, 0.18, 10.0), Vector3(2, 0.09, 1.8), mat_asphalt)
	box(parent, Vector3(52, 0.45, 0.55), Vector3(2, 0.22, -3.4), mat_curb)
	box(parent, Vector3(52, 0.45, 0.55), Vector3(2, 0.22, 7.0), mat_curb)
	decal_quad(parent, "decal_lane_solid.png", Vector2(50, 0.22), Vector3(2, 0.20, -2.7), 0.0)
	decal_quad(parent, "decal_lane_solid.png", Vector2(50, 0.22), Vector3(2, 0.20, 6.3), 0.0)
	for x in range(-22, 24, 4):
		decal_quad(parent, "decal_lane_dash.png", Vector2(2.2, 0.28), Vector3(float(x), 0.20, 1.8), 0.0)
	decal_quad(parent, "decal_arrow.png", Vector2(2.0, 3.2), Vector3(6.5, 0.21, 1.8), 0.0)
	decal_quad(parent, "decal_turn_arrow.png", Vector2(2.6, 2.6), Vector3(-5.5, 0.21, 3.6), deg_to_rad(20))

## Dense overlapping ramp deck (proxy for spline road). segs=40 default.
func build_ramp(parent: Node3D, segs := 40) -> Node3D:
	var ramp := Node3D.new()
	ramp.name = "Ramp"
	parent.add_child(ramp)
	for i in segs:
		var t := float(i) / float(segs - 1)
		var ang := lerpf(deg_to_rad(-52), deg_to_rad(72), t)
		var radius := 20.5
		var cx := -3.5 + cos(ang) * radius * 0.62
		var cz := -3.5 + sin(ang) * radius * 0.78
		var y := lerpf(1.5, 5.4, t)
		var yaw := ang + deg_to_rad(90.0)
		box(ramp, Vector3(8.6, 0.28, 3.8), Vector3(cx, y, cz), mat_asphalt, yaw)
		box(ramp, Vector3(8.8, 0.48, 4.0), Vector3(cx, y - 0.30, cz), mat_concrete, yaw)
		if i % 2 == 0:
			decal_quad(ramp, "decal_lane_dash.png", Vector2(1.5, 0.2), Vector3(cx, y + 0.17, cz), yaw)
		if i % 5 == 0:
			var ph := y + 0.2
			box(ramp, Vector3(1.35, ph, 1.35), Vector3(cx, ph * 0.5 - 0.2, cz), mat_concrete)
			box(ramp, Vector3(2.0, 0.35, 2.0), Vector3(cx, y - 0.55, cz), mat_concrete)
	return ramp

## Glass office proxy + ReflectionProbe.
func build_glass_building(parent: Node3D) -> Node3D:
	var bldg := Node3D.new()
	bldg.name = "GlassBuilding"
	parent.add_child(bldg)
	for i in 5:
		for j in 3:
			box(bldg, Vector3(0.9, 3.6, 0.9), Vector3(12 + i * 2.8, 1.8, -4 + j * 4.2), mat_concrete)
	box(bldg, Vector3(15.5, 0.6, 14.5), Vector3(17.5, 3.7, 0.5), mat_concrete)
	for row in 7:
		for col in 8:
			var gx := 11.2 + col * 1.72
			var gy := 4.2 + row * 1.65
			box(bldg, Vector3(1.55, 1.5, 0.08), Vector3(gx, gy, -6.45), mat_glass, 0.0, false)
			box(bldg, Vector3(0.08, 1.5, 1.55), Vector3(11.0, gy, -5.4 + col * 1.45), mat_glass, 0.0, false)
	for col in 9:
		box(bldg, Vector3(0.14, 12.5, 0.14), Vector3(11.1 + col * 1.72, 9.2, -6.4), mat_frame)
	for row in 8:
		box(bldg, Vector3(14.5, 0.1, 0.1), Vector3(17.5, 4.15 + row * 1.65, -6.4), mat_frame)
	box(bldg, Vector3(15.8, 0.5, 14.8), Vector3(17.5, 15.6, 0.5), mat_concrete)
	box(bldg, Vector3(14.8, 12.0, 0.55), Vector3(17.5, 9.3, 7.4), mat_concrete)
	box(bldg, Vector3(0.45, 12.0, 14.0), Vector3(25.2, 9.3, 0.5), mat_concrete)
	var probe := ReflectionProbe.new()
	probe.position = Vector3(17.5, 8.0, -2.0)
	probe.size = Vector3(28, 22, 28)
	probe.max_distance = 40.0
	probe.intensity = 0.85
	probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
	probe.ambient_mode = ReflectionProbe.AMBIENT_ENVIRONMENT
	parent.add_child(probe)
	return bldg

## Tree proxy: bark cylinder + crossed canopy billboards + soft volume sphere.
func build_tree(parent: Node3D, pos: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "ProxyTree"
	root.position = pos
	parent.add_child(root)
	cyl(root, 0.18, 0.28, 1.4, Vector3(0, 0.7, 0), mat_bark)
	var q1 := QuadMesh.new(); q1.size = Vector2(2.8, 2.8)
	mi(root, q1, Vector3(0, 2.3, 0), mat_canopy, Vector3.ZERO, true)
	var q2 := QuadMesh.new(); q2.size = Vector2(2.8, 2.8)
	mi(root, q2, Vector3(0, 2.3, 0), mat_canopy, Vector3(0, deg_to_rad(90), 0), true)
	var sph := SphereMesh.new()
	sph.radius = 0.95
	sph.height = 1.7
	var soft := mat_canopy.duplicate() as StandardMaterial3D
	soft.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	soft.albedo_color = Color(0.25, 0.55, 0.22, 0.55)
	soft.albedo_texture = null
	mi(root, sph, Vector3(0, 2.35, 0), soft, Vector3.ZERO, true)
	return root

## Vehicle proxy: body + cabin glass + wheels. MultiMesh-friendly silhouette.
func build_vehicle(parent: Node3D, pos: Vector3, yaw: float, body: Material, van := false) -> Node3D:
	var root := Node3D.new()
	root.name = "ProxyVehicle"
	root.position = pos
	root.rotation.y = yaw
	parent.add_child(root)
	var L := 2.15 if not van else 2.7
	var H := 0.72 if not van else 1.2
	var W := 1.05 if not van else 1.2
	box(root, Vector3(L, H, W), Vector3(0, H * 0.55, 0), body)
	var cabin_h := 0.5 if not van else 0.45
	var cabin_l := 0.85 if not van else 0.9
	var cabin_off: float = -0.25 if not van else -0.55
	box(root, Vector3(cabin_l, cabin_h, W * 0.92), Vector3(cabin_off, H * 0.55 + cabin_h * 0.55, 0), mat_v_glass, 0.0, false)
	var wheel := CylinderMesh.new()
	wheel.top_radius = 0.22
	wheel.bottom_radius = 0.22
	wheel.height = 0.18
	wheel.radial_segments = 12
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.08, 0.08, 0.09)
	wmat.roughness = 0.7
	for lon_v in [-0.65, 0.65]:
		for lat_v in [-1.0, 1.0]:
			var lon: float = float(lon_v)
			var lat: float = float(lat_v)
			var wp := Vector3(lon * (L * 0.35), 0.22, lat * (W * 0.55))
			mi(root, wheel, wp, wmat, Vector3(deg_to_rad(90), 0, 0))
	return root

## Overlay accents only — do not tint world materials.
func build_overlay_accents(parent: Node3D) -> void:
	_l_bracket(parent, Vector3(-18, 0.4, -12), mat_fa, false)
	_l_bracket(parent, Vector3(-18, 0.4, 12), mat_fa, true)
	_l_bracket(parent, Vector3(22, 0.4, -10), mat_fb, false)
	_l_bracket(parent, Vector3(22, 0.4, 11), mat_fb, true)
	box(parent, Vector3(1.0, 0.1, 1.0), Vector3(9.5, 0.3, 0.2), mat_power, deg_to_rad(45), false)
	box(parent, Vector3(14, 0.08, 0.4), Vector3(-2, 0.24, 6.5), mat_cong, 0.0, false)

func _l_bracket(parent: Node3D, pos: Vector3, mat: Material, flip: bool) -> void:
	var s := -1.0 if flip else 1.0
	box(parent, Vector3(3.5, 0.18, 0.35), pos + Vector3(1.5, 0, 0), mat, 0.0, false)
	box(parent, Vector3(0.35, 0.18, 3.5), pos + Vector3(0, 0, s * 1.5), mat, 0.0, false)

## Full interchange sample content (no HUD, no cameras).
func build_interchange_world(parent: Node3D) -> void:
	ensure_materials()
	for c in parent.get_children():
		c.queue_free()
	box(parent, Vector3(100, 0.3, 100), Vector3(8, -0.15, 0), mat_grass, 0.0, false)
	build_ground_road(parent)
	build_ramp(parent, 40)
	box(parent, Vector3(18, 2.8, 0.7), Vector3(-14, 1.4, -7.2), mat_concrete, deg_to_rad(22))
	box(parent, Vector3(14, 2.4, 0.7), Vector3(-8, 1.2, 8.8), mat_concrete, deg_to_rad(-18))
	build_glass_building(parent)
	for p in [
		Vector3(-8, 0, -11), Vector3(-5.2, 0, -12.2), Vector3(-2.5, 0, -10.8),
		Vector3(0.5, 0, -11.5), Vector3(3.5, 0, 10.2), Vector3(6.2, 0, 11.4),
		Vector3(9.0, 0, 9.8), Vector3(11.5, 0, 10.8), Vector3(-16, 0, 3.5),
		Vector3(-13.5, 0, 5.2), Vector3(-15, 0, 6.8), Vector3(8.5, 0, -10.5)
	]:
		build_tree(parent, p)
	build_vehicle(parent, Vector3(-1.2, 4.05, -1.5), deg_to_rad(50), mat_v_dark, false)
	build_vehicle(parent, Vector3(5.8, 4.75, 3.2), deg_to_rad(64), mat_v_white, true)
	build_vehicle(parent, Vector3(7.8, 0.42, 3.4), deg_to_rad(-10), mat_v_blue, false)
	build_vehicle(parent, Vector3(-9.5, 0.42, 0.6), deg_to_rad(6), mat_v_dark, false)
	build_overlay_accents(parent)

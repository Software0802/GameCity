extends RefCounted
## Procedural parked-car meshes (sedan, hatch, suv, van). One ArrayMesh per variant, three surfaces:
## 0 paint (vertex colour white, tinted per instance), 1 glass, 2 trim (tyres, bumpers, lights).
## The car faces +X, centred on x=z=0, wheels on y=0.

const MB := preload("res://client/assets/techart/showcase_max/scripts/mesh_batch.gd")

static func _extrude_xy(bt: RefCounted, poly: PackedVector2Array, z0: float, z1: float, col: Color, caps := true) -> void:
	var cw := Geometry2D.is_polygon_clockwise(poly)
	var n := poly.size()
	for i in n:
		var p := poly[i]
		var q := poly[(i + 1) % n]
		var e := q - p
		if e.length() < 1e-4:
			continue
		var out := Vector2(e.y, -e.x).normalized()
		if cw:
			out = -out
		var nrm := Vector3(out.x, out.y, 0.0)
		bt.quad(Vector3(p.x, p.y, z1), Vector3(q.x, q.y, z1), Vector3(q.x, q.y, z0), Vector3(p.x, p.y, z0), nrm,
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), col)
	if caps:
		var tri := Geometry2D.triangulate_polygon(poly)
		for k in range(0, tri.size(), 3):
			var a := poly[tri[k]]
			var b := poly[tri[k + 1]]
			var c := poly[tri[k + 2]]
			bt.tri(Vector3(a.x, a.y, z1), Vector3(b.x, b.y, z1), Vector3(c.x, c.y, z1), Vector3.BACK, a, b, c, col)
			bt.tri(Vector3(a.x, a.y, z0), Vector3(b.x, b.y, z0), Vector3(c.x, c.y, z0), Vector3.FORWARD, a, b, c, col)

static func _wheel(tr: RefCounted, x: float, z: float, r: float, w: float) -> void:
	# axis along z; lathe builds around Y, so build then rotate
	var tmp = MB.new()
	tmp.lathe(Vector3.ZERO, [Vector2(0.0, -w * 0.5), Vector2(r * 0.86, -w * 0.5), Vector2(r, -w * 0.38), Vector2(r, w * 0.38), Vector2(r * 0.86, w * 0.5), Vector2(0.0, w * 0.5)], 14, Color(0.05, 0.05, 0.055))
	tr.append_transformed(tmp, Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0)), Vector3(x, r, z)))
	var rim = MB.new()
	var s := 1.0 if z > 0.0 else -1.0
	rim.lathe(Vector3.ZERO, [Vector2(0.0, w * 0.52), Vector2(r * 0.62, w * 0.52)], 12, Color(0.62, 0.64, 0.66))
	tr.append_transformed(rim, Transform3D(Basis(Vector3.RIGHT, deg_to_rad(90.0 * s)), Vector3(x, r, z + s * 0.0)))

static func make(variant: int) -> ArrayMesh:
	var paint = MB.new()
	var glass = MB.new()
	var trim = MB.new()
	var lights = MB.new()
	var L := 4.5
	var W := 1.8
	var lower: PackedVector2Array
	var cabin: PackedVector2Array
	var roof_x0 := -0.78
	var roof_x1 := 0.55
	var roof_y := 1.44
	match variant:
		0:  # sedan
			lower = PackedVector2Array([Vector2(-2.20, 0.32), Vector2(-2.24, 0.82), Vector2(-1.72, 0.97), Vector2(-1.15, 1.0), Vector2(0.95, 1.02), Vector2(1.62, 0.93), Vector2(2.18, 0.8), Vector2(2.24, 0.48), Vector2(2.02, 0.3)])
			cabin = PackedVector2Array([Vector2(-1.18, 1.0), Vector2(-0.80, 1.44), Vector2(0.55, 1.46), Vector2(1.08, 1.02)])
		1:  # hatchback
			L = 4.0
			lower = PackedVector2Array([Vector2(-1.98, 0.32), Vector2(-2.0, 0.9), Vector2(-1.9, 1.02), Vector2(0.78, 1.04), Vector2(1.40, 0.95), Vector2(1.96, 0.82), Vector2(2.02, 0.48), Vector2(1.8, 0.3)])
			cabin = PackedVector2Array([Vector2(-1.9, 1.02), Vector2(-1.55, 1.5), Vector2(0.35, 1.52), Vector2(0.92, 1.05)])
			roof_x0 = -1.55
			roof_x1 = 0.35
			roof_y = 1.52
		2:  # suv
			L = 4.7
			W = 1.88
			lower = PackedVector2Array([Vector2(-2.32, 0.40), Vector2(-2.36, 1.05), Vector2(-2.1, 1.15), Vector2(0.9, 1.15), Vector2(1.7, 1.02), Vector2(2.3, 0.9), Vector2(2.36, 0.55), Vector2(2.1, 0.38)])
			cabin = PackedVector2Array([Vector2(-2.1, 1.15), Vector2(-1.95, 1.72), Vector2(0.45, 1.74), Vector2(1.05, 1.17)])
			roof_x0 = -1.95
			roof_x1 = 0.45
			roof_y = 1.74
		_:  # van
			L = 5.2
			W = 1.95
			lower = PackedVector2Array([Vector2(-2.6, 0.40), Vector2(-2.62, 1.55), Vector2(1.2, 1.6), Vector2(1.85, 1.2), Vector2(2.55, 1.0), Vector2(2.6, 0.55), Vector2(2.3, 0.38)])
			cabin = PackedVector2Array([Vector2(1.2, 1.6), Vector2(1.55, 1.95), Vector2(1.0, 2.0), Vector2(-2.55, 2.02), Vector2(-2.6, 1.6)])
			roof_x0 = -2.55
			roof_x1 = 1.0
			roof_y = 2.02
	var hw := W * 0.5
	_extrude_xy(paint, lower, -hw, hw, Color.WHITE)
	# cabin: glass prism slightly narrower, paint roof slab and pillars
	_extrude_xy(glass, cabin, -hw + 0.16, hw - 0.16, Color(0.07, 0.1, 0.13))
	paint.box(Vector3(roof_x0 + 0.02, roof_y - 0.02, -hw + 0.12), Vector3(roof_x1, roof_y + 0.045, hw - 0.12), Color.WHITE, 0x37)
	var pil := 0.05
	for zz: float in [-1.0, 1.0]:
		var zc := zz * (hw - 0.16)
		var cb := cabin[0]
		var cf := cabin[cabin.size() - 1]
		paint.box(Vector3(cb.x, cb.y, zc - 0.03), Vector3(cb.x + 0.12, roof_y, zc + 0.03), Color.WHITE, 0x37)
		paint.box(Vector3(roof_x1 - 0.04, cf.y, zc - 0.03), Vector3(roof_x1 + 0.4, roof_y - 0.01, zc + 0.03), Color.WHITE, 0x37)
	# bumpers and lights
	var lo_front := lower[lower.size() - 2].x
	var lo_rear := lower[0].x
	trim.box(Vector3(lo_front - 0.05, 0.28, -hw + 0.04), Vector3(lo_front + 0.1, 0.52, hw - 0.04), Color(0.09, 0.09, 0.1), 0x37)
	trim.box(Vector3(lo_rear - 0.1, 0.28, -hw + 0.04), Vector3(lo_rear + 0.05, 0.52, hw - 0.04), Color(0.09, 0.09, 0.1), 0x37)
	for zz: float in [-1.0, 1.0]:
		lights.box(Vector3(lo_front + 0.02, 0.62, zz * 0.62 - 0.17), Vector3(lo_front + 0.08, 0.76, zz * 0.62 + 0.17), Color(1.0, 0.97, 0.88, 1.0), 0x37)
		lights.box(Vector3(lo_rear - 0.08, 0.68 if variant < 3 else 0.9, zz * 0.66 - 0.16), Vector3(lo_rear - 0.01, 0.78 if variant < 3 else 1.04, zz * 0.66 + 0.16), Color(0.9, 0.05, 0.04, 1.0), 0x37)
	# wheels
	var wr := 0.34 if variant < 2 else 0.38
	var wx := L * 0.5 - 0.88
	for xs: float in [-1.0, 1.0]:
		for zs: float in [-1.0, 1.0]:
			_wheel(trim, xs * wx, zs * (hw - 0.12), wr, 0.25)
	# mirrors
	for zz: float in [-1.0, 1.0]:
		paint.box(Vector3(roof_x1 + 0.2 - 0.24, 1.02, zz * (hw + 0.06) - 0.06), Vector3(roof_x1 + 0.2, 1.12, zz * (hw + 0.06) + 0.06), Color.WHITE, 0x37)
	var mesh := ArrayMesh.new()
	paint.commit(mesh)
	glass.commit(mesh)
	trim.commit(mesh)
	lights.commit(mesh)
	return mesh

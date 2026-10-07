extends RefCounted
## Triangle accumulator for one material surface, adapted from showcase mesh_batch.gd.
## Differences for the live client: triangles are stored NON-indexed so two batches merge
## with plain PackedArray.append_array (no per-index offset loop); append_with_alpha()
## rewrites the vertex-colour alpha while merging (facade window state); commit() keeps
## the showcase vertex layout (UV metres, UV2, COLOR, tangents, optional CUSTOM0).
## Godot front faces are clockwise; quad() takes the outward normal and fixes the winding.

var verts := PackedVector3Array()
var norms := PackedVector3Array()
var uvs := PackedVector2Array()
var uv2s := PackedVector2Array()
var cols := PackedColorArray()
var tans := PackedFloat32Array()
var custom0 := PackedFloat32Array()   # 4 floats per vertex when use_custom0
var use_custom0 := false


func count() -> int:
	return verts.size()


func tri_count() -> int:
	return verts.size() / 3


func is_empty() -> bool:
	return verts.is_empty()


func clear() -> void:
	verts.clear()
	norms.clear()
	uvs.clear()
	uv2s.clear()
	cols.clear()
	tans.clear()
	custom0.clear()


## Merge another batch (same use_custom0) by memcpy.
func append(other: RefCounted) -> void:
	verts.append_array(other.verts)
	norms.append_array(other.norms)
	uvs.append_array(other.uvs)
	uv2s.append_array(other.uv2s)
	cols.append_array(other.cols)
	tans.append_array(other.tans)
	if use_custom0:
		if other.use_custom0:
			custom0.append_array(other.custom0)
		else:
			var pad := PackedFloat32Array()
			pad.resize(other.verts.size() * 4)
			custom0.append_array(pad)


## Vertex colours of `other` with every alpha replaced (facade shader reads COLOR.a as window state).
static func colors_with_alpha(other: RefCounted, alpha: float) -> PackedColorArray:
	var patched: PackedColorArray = other.cols.duplicate()
	for i in patched.size():
		var c: Color = patched[i]
		c.a = alpha
		patched[i] = c
	return patched


## Merge with every vertex-colour alpha replaced.
func append_with_alpha(other: RefCounted, alpha: float) -> void:
	append_with_colors(other, colors_with_alpha(other, alpha))


## Merge with a precomputed vertex-colour array (same length as other.cols).
func append_with_colors(other: RefCounted, patched: PackedColorArray) -> void:
	verts.append_array(other.verts)
	norms.append_array(other.norms)
	uvs.append_array(other.uvs)
	uv2s.append_array(other.uv2s)
	cols.append_array(patched)
	tans.append_array(other.tans)
	if use_custom0:
		if other.use_custom0:
			custom0.append_array(other.custom0)
		else:
			var pad := PackedFloat32Array()
			pad.resize(other.verts.size() * 4)
			custom0.append_array(pad)


func _push(p: Vector3, n: Vector3, uv: Vector2, uv2: Vector2, col: Color, t: Vector3, w: float, c0: Color) -> void:
	verts.append(p)
	norms.append(n)
	uvs.append(uv)
	uv2s.append(uv2)
	cols.append(col)
	tans.append(t.x)
	tans.append(t.y)
	tans.append(t.z)
	tans.append(w)
	if use_custom0:
		custom0.append(c0.r)
		custom0.append(c0.g)
		custom0.append(c0.b)
		custom0.append(c0.a)


static func cross_dot(n: Vector3, t: Vector3, bt: Vector3) -> float:
	return n.cross(t).dot(bt)


## Quad from four perimeter corners (a,b,c,d in order) with explicit outward normal.
## ua..ud are the UVs of the corners. col/uv2/c0 are per-quad attributes; uv2v (4 entries)
## overrides uv2 per corner.
func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2,
		col := Color.WHITE, uv2 := Vector2.ZERO, c0 := Color(0, 0, 0, 0), uv2v: Array = []) -> void:
	var e1 := b - a
	var e2 := d - a
	var d1 := ub - ua
	var d2 := ud - ua
	var det := d1.x * d2.y - d2.x * d1.y
	var t := e1.normalized()
	var bt := e2.normalized()
	if absf(det) > 1e-9:
		t = ((e1 * d2.y - e2 * d1.y) / det).normalized()
		bt = ((e2 * d1.x - e1 * d2.x) / det).normalized()
	var w := -1.0 if cross_dot(n, t, bt) > 0.0 else 1.0
	var pts := [a, b, c, d]
	var uvl := [ua, ub, uc, ud]
	var per := uv2v.size() == 4
	var ccw := (b - a).cross(c - a).dot(n) > 0.0
	var order: Array = [0, 2, 1, 0, 3, 2] if ccw else [0, 1, 2, 0, 2, 3]
	for k in order:
		_push(pts[k], n, uvl[k], uv2v[k] if per else uv2, col, t, w, c0)


## Triangle with flat normal and planar UVs.
func tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3, ua: Vector2, ub: Vector2, uc: Vector2,
		col := Color.WHITE, uv2 := Vector2.ZERO, c0 := Color(0, 0, 0, 0), uv2v: Array = []) -> void:
	var e1 := b - a
	var e2 := c - a
	var d1 := ub - ua
	var d2 := uc - ua
	var det := d1.x * d2.y - d2.x * d1.y
	var t := e1.normalized()
	var bt := e2.normalized()
	if absf(det) > 1e-9:
		t = ((e1 * d2.y - e2 * d1.y) / det).normalized()
		bt = ((e2 * d1.x - e1 * d2.x) / det).normalized()
	var w := -1.0 if cross_dot(n, t, bt) > 0.0 else 1.0
	var pts := [a, b, c]
	var uvl := [ua, ub, uc]
	var per := uv2v.size() == 3
	var ccw := (b - a).cross(c - a).dot(n) > 0.0
	var order: Array = [0, 2, 1] if ccw else [0, 1, 2]
	for k in order:
		_push(pts[k], n, uvl[k], uv2v[k] if per else uv2, col, t, w, c0)


## Horizontal rectangle facing up (+Y) or down. UV = world xz in metres * uv_scale.
func rect_xz(x0: float, z0: float, x1: float, z1: float, y: float, up := true,
		uv_scale := 1.0, col := Color.WHITE, uv_off := Vector2.ZERO, uv2 := Vector2.ZERO) -> void:
	var n := Vector3.UP if up else Vector3.DOWN
	quad(Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), n,
		Vector2(x0, z0) * uv_scale + uv_off, Vector2(x1, z0) * uv_scale + uv_off,
		Vector2(x1, z1) * uv_scale + uv_off, Vector2(x0, z1) * uv_scale + uv_off, col, uv2)


## Axis-aligned box [lo, hi]. Side UVs are metres (u along wall, v = -height from lo.y).
## faces: bitmask 1=+X 2=-X 4=+Y 8=-Y 16=+Z 32=-Z. Top UV = xz metres.
func box(lo: Vector3, hi: Vector3, col := Color.WHITE, faces := 0x37, uv_scale := 1.0,
		uv2 := Vector2.ZERO, c0 := Color(0, 0, 0, 0)) -> void:
	var s := uv_scale
	var h := (hi.y - lo.y) * s
	if faces & 16:
		quad(Vector3(lo.x, hi.y, hi.z), Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3.BACK,
			Vector2(lo.x * s, -h), Vector2(hi.x * s, -h), Vector2(hi.x * s, 0), Vector2(lo.x * s, 0), col, uv2, c0)
	if faces & 32:
		quad(Vector3(hi.x, hi.y, lo.z), Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3.FORWARD,
			Vector2(-hi.x * s, -h), Vector2(-lo.x * s, -h), Vector2(-lo.x * s, 0), Vector2(-hi.x * s, 0), col, uv2, c0)
	if faces & 1:
		quad(Vector3(hi.x, hi.y, hi.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3.RIGHT,
			Vector2(-hi.z * s, -h), Vector2(-lo.z * s, -h), Vector2(-lo.z * s, 0), Vector2(-hi.z * s, 0), col, uv2, c0)
	if faces & 2:
		quad(Vector3(lo.x, hi.y, lo.z), Vector3(lo.x, hi.y, hi.z), Vector3(lo.x, lo.y, hi.z), Vector3(lo.x, lo.y, lo.z), Vector3.LEFT,
			Vector2(lo.z * s, -h), Vector2(hi.z * s, -h), Vector2(hi.z * s, 0), Vector2(lo.z * s, 0), col, uv2, c0)
	if faces & 4:
		quad(Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z), Vector3.UP,
			Vector2(lo.x, lo.z) * s, Vector2(hi.x, lo.z) * s, Vector2(hi.x, hi.z) * s, Vector2(lo.x, hi.z) * s, col, uv2, c0)
	if faces & 8:
		quad(Vector3(lo.x, lo.y, hi.z), Vector3(hi.x, lo.y, hi.z), Vector3(hi.x, lo.y, lo.z), Vector3(lo.x, lo.y, lo.z), Vector3.DOWN,
			Vector2(lo.x, hi.z) * s, Vector2(hi.x, hi.z) * s, Vector2(hi.x, lo.z) * s, Vector2(lo.x, lo.z) * s, col, uv2, c0)


## Box rotated by yaw (radians) around its centre; size in metres. Same UV rule as box().
func box_yaw(center: Vector3, size: Vector3, yaw: float, col := Color.WHITE, faces := 0x37,
		uv_scale := 1.0, uv2 := Vector2.ZERO, c0 := Color(0, 0, 0, 0)) -> void:
	var start := verts.size()
	box(-size * 0.5, size * 0.5, col, faces, uv_scale, uv2, c0)
	var basis := Basis(Vector3.UP, yaw)
	for k in range(start, verts.size()):
		verts[k] = basis * verts[k] + center
		norms[k] = basis * norms[k]
		var tv := Vector3(tans[k * 4], tans[k * 4 + 1], tans[k * 4 + 2])
		tv = basis * tv
		tans[k * 4] = tv.x
		tans[k * 4 + 1] = tv.y
		tans[k * 4 + 2] = tv.z


## Append another batch transformed by a Transform3D (stamping prebuilt pieces).
func append_transformed(other: RefCounted, xf: Transform3D) -> void:
	var nb := xf.basis
	var nbn := nb.inverse().transposed()
	for k in other.verts.size():
		verts.append(xf * other.verts[k])
		norms.append((nbn * other.norms[k]).normalized())
		uvs.append(other.uvs[k])
		uv2s.append(other.uv2s[k])
		cols.append(other.cols[k])
		var tv := Vector3(other.tans[k * 4], other.tans[k * 4 + 1], other.tans[k * 4 + 2])
		tv = (nb * tv).normalized()
		tans.append(tv.x)
		tans.append(tv.y)
		tans.append(tv.z)
		tans.append(other.tans[k * 4 + 3])
		if use_custom0:
			for q in 4:
				custom0.append(other.custom0[k * 4 + q] if other.use_custom0 else 0.0)


## Lathe (surface of revolution) about the Y axis. profile = Array of Vector2(radius, y). Smooth normals.
func lathe(center: Vector3, profile: Array, segments: int, col := Color.WHITE, uv_scale := 1.0,
		uv2 := Vector2.ZERO, c0 := Color(0, 0, 0, 0)) -> void:
	var rings := profile.size()
	var grid_p: Array = []
	var grid_n: Array = []
	var grid_uv: Array = []
	for i in rings:
		var pr: Vector2 = profile[i]
		var prev: Vector2 = profile[maxi(i - 1, 0)]
		var next: Vector2 = profile[mini(i + 1, rings - 1)]
		var tang := (next - prev)
		var nrm2 := Vector2(tang.y, -tang.x).normalized()
		for s in segments + 1:
			var a := TAU * float(s) / float(segments)
			var ca := cos(a)
			var sa := sin(a)
			grid_p.append(center + Vector3(ca * pr.x, pr.y, sa * pr.x))
			grid_n.append(Vector3(ca * nrm2.x, nrm2.y, sa * nrm2.x).normalized())
			grid_uv.append(Vector2(float(s) / float(segments) * TAU * maxf(pr.x, 0.05) * uv_scale, -pr.y * uv_scale))
	for i in rings - 1:
		for s in segments:
			var a0 := i * (segments + 1) + s
			var a1 := a0 + 1
			var b0 := a0 + segments + 1
			var b1 := b0 + 1
			var tri_n: Vector3 = (grid_p[b0] - grid_p[a0]).cross(grid_p[a1] - grid_p[a0])
			var order: Array
			if tri_n.dot(grid_n[a0]) > 0.0:
				order = [a0, a1, b0, a1, b1, b0]
			else:
				order = [a0, b0, a1, a1, b0, b1]
			for k in order:
				var ang := TAU * float(k % (segments + 1)) / float(segments)
				var tv := Vector3(-sin(ang), 0.0, cos(ang))
				_push(grid_p[k], grid_n[k], grid_uv[k], uv2, col, tv, 1.0, c0)


## Extruded prism from a 2D polygon (XZ) between y0 and y1, side walls plus optional caps.
func prism(poly: PackedVector2Array, y0: float, y1: float, col := Color.WHITE, top := true, bottom := false,
		uv_scale := 1.0, uv2 := Vector2.ZERO, c0 := Color(0, 0, 0, 0)) -> void:
	var cnt := poly.size()
	var ccw2 := Geometry2D.is_polygon_clockwise(poly) == false
	var run := 0.0
	for i in cnt:
		var p := poly[i]
		var q := poly[(i + 1) % cnt]
		var seg := q - p
		var len := seg.length()
		if len < 1e-4:
			continue
		var out2 := Vector2(seg.y, -seg.x).normalized()
		if not ccw2:
			out2 = -out2
		var nrm := Vector3(out2.x, 0, out2.y)
		quad(Vector3(p.x, y1, p.y), Vector3(q.x, y1, q.y), Vector3(q.x, y0, q.y), Vector3(p.x, y0, p.y), nrm,
			Vector2(run, -(y1 - y0)) * uv_scale, Vector2(run + len, -(y1 - y0)) * uv_scale,
			Vector2(run + len, 0) * uv_scale, Vector2(run, 0) * uv_scale, col, uv2, c0)
		run += len
	if top or bottom:
		var tri_idx := Geometry2D.triangulate_polygon(poly)
		for k in range(0, tri_idx.size(), 3):
			var a := poly[tri_idx[k]]
			var b := poly[tri_idx[k + 1]]
			var c := poly[tri_idx[k + 2]]
			if top:
				tri(Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y), Vector3(c.x, y1, c.y), Vector3.UP,
					a * uv_scale, b * uv_scale, c * uv_scale, col, uv2, c0)
			if bottom:
				tri(Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(c.x, y0, c.y), Vector3.DOWN,
					a * uv_scale, b * uv_scale, c * uv_scale, col, uv2, c0)


## Commit into an ArrayMesh as one non-indexed surface. Returns the surface index or -1 when empty.
func commit(mesh: ArrayMesh, mat: Material = null) -> int:
	if verts.is_empty():
		return -1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TANGENT] = tans
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	var flags := 0
	if use_custom0:
		arrays[Mesh.ARRAY_CUSTOM0] = custom0
		flags |= Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	var s := mesh.get_surface_count() - 1
	if mat != null:
		mesh.surface_set_material(s, mat)
	return s

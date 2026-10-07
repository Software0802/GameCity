extends RefCounted
## CPU model of Godot's Environment ACES tonemapper + the Adjustments pass, and its numerical inverse.
## Overlay colours (faction, zone, power, congestion) must read as the palette hex values in the final image,
## but ACES desaturates and brightens anything bright. We solve for the linear colour that lands on the hex.
## Validated against measured output (see docs/REPORT.md "Palette fidelity").

const A := 0.0245786
const B := 0.000090537
const C := 0.983729
const D := 0.432951
const E := 0.238081
const BIAS := 1.8

static func _curve(x: Vector3) -> Vector3:
	return Vector3(
		(x.x * (x.x + A) - B) / (x.x * (C * x.x + D) + E),
		(x.y * (x.y + A) - B) / (x.y * (C * x.y + D) + E),
		(x.z * (x.z + A) - B) / (x.z * (C * x.z + D) + E))

static func _rrt(v: Vector3) -> Vector3:
	return Vector3(
		v.dot(Vector3(0.59719, 0.35458, 0.04823)),
		v.dot(Vector3(0.07600, 0.90834, 0.01566)),
		v.dot(Vector3(0.02840, 0.13383, 0.83777))) * BIAS

static func _odt(v: Vector3) -> Vector3:
	return Vector3(
		v.dot(Vector3(1.60475, -0.53108, -0.07367)),
		v.dot(Vector3(-0.10208, 1.10813, -0.00605)),
		v.dot(Vector3(-0.00327, -0.07276, 1.07602)))

static func _lin_to_srgb(c: float) -> float:
	c = clampf(c, 0.0, 1.0)
	return c * 12.92 if c < 0.0031308 else 1.055 * pow(c, 1.0 / 2.4) - 0.055

static func _srgb_to_lin(c: float) -> float:
	return c / 12.92 if c < 0.04045 else pow((c + 0.055) / 1.055, 2.4)

## linear scene colour -> final display colour (0..1 sRGB), exposure/white/contrast/saturation as in Environment.
static func forward(lin: Vector3, exposure: float, white: float, contrast: float, saturation: float) -> Vector3:
	var x := lin * exposure
	var t := _odt(_curve(_rrt(x)))
	var w := _curve(Vector3(white * BIAS, white * BIAS, white * BIAS)).x
	t = (t / w).clamp(Vector3.ZERO, Vector3.ONE)
	var s := Vector3(_lin_to_srgb(t.x), _lin_to_srgb(t.y), _lin_to_srgb(t.z))
	# Adjustments (contrast about 0.5, then saturation about luma), applied after tonemapping.
	s = Vector3(0.5, 0.5, 0.5).lerp(s, contrast)
	var luma := s.dot(Vector3(0.2126, 0.7152, 0.0722))
	s = Vector3(luma, luma, luma).lerp(s, saturation)
	return s.clamp(Vector3.ZERO, Vector3.ONE)

## Linear colour that displays as `target` (an sRGB colour such as a palette hex). Returns {lin, err}.
## Damped Gauss-Newton with backtracking, several starting points, best residual wins.
static func inverse(target: Color, exposure: float, white: float, contrast: float, saturation: float) -> Dictionary:
	var tgt := Vector3(target.r, target.g, target.b)
	var base := Vector3(_srgb_to_lin(target.r), _srgb_to_lin(target.g), _srgb_to_lin(target.b))
	var best_x := base
	var best_err := 9.0
	for start in [0.6, 0.25, 1.4, 0.08]:
		var x: Vector3 = base * float(start) + Vector3(0.002, 0.002, 0.002)
		var err := (forward(x, exposure, white, contrast, saturation) - tgt).length()
		for it in 60:
			if err < 0.002:
				break
			var f := forward(x, exposure, white, contrast, saturation) - tgt
			var eps := 0.003
			var cols: Array = []
			for k in 3:
				var d := Vector3.ZERO
				d[k] = eps
				cols.append((forward(x + d, exposure, white, contrast, saturation) - forward(x - d, exposure, white, contrast, saturation)) / (2.0 * eps))
			var j := Basis(cols[0], cols[1], cols[2])
			var step: Vector3
			if absf(j.determinant()) < 1e-10:
				step = -f * 0.3          # gradient-free nudge when a channel is clipped
			else:
				step = -(j.inverse() * f)
			var t := 1.0
			var improved := false
			for ls in 8:
				var xn := (x + step * t).clamp(Vector3.ZERO, Vector3(60, 60, 60))
				var en := (forward(xn, exposure, white, contrast, saturation) - tgt).length()
				if en < err:
					x = xn
					err = en
					improved = true
					break
				t *= 0.5
			if not improved:
				break
		if err < best_err:
			best_err = err
			best_x = x
	return {"lin": best_x, "err": best_err}

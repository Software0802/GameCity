shader_type spatial;
// Cheap lamp light pool: additive radial falloff quad on the ground, visible only at night.
// Covers the street lamps beyond the OmniLight budget so far shots still read as lit streets.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform float night = 0.0;
uniform float gain = 1.0;

void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float r = length(q);
	float f = pow(clamp(1.0 - r, 0.0, 1.0), 2.2);
	ALBEDO = COLOR.rgb * f * gain * night;
	ALPHA = 1.0;
}

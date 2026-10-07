shader_type spatial;
// Chain-link fence panel: analytically anti-aliased diamond wire pattern (coverage fades to a uniform
// translucent veil when the wires are smaller than a pixel, so far shots do not shimmer).
render_mode blend_mix, cull_disabled, depth_draw_opaque;

uniform float cell = 0.22;
uniform float wire = 0.014;

void fragment() {
	vec2 q = UV / cell;
	float px = max(fwidth(q.x) + fwidth(q.y), 1e-4);
	float a = abs(fract(q.x + q.y) - 0.5);
	float b = abs(fract(q.x - q.y) - 0.5);
	float d = min(a, b) * cell;
	float w = wire;
	float aa = px * cell * 0.7;
	float cov = 1.0 - smoothstep(w * 0.5, w * 0.5 + aa, d);
	ALBEDO = vec3(0.55, 0.57, 0.6);
	METALLIC = 0.7;
	ROUGHNESS = 0.45;
	ALPHA = clamp(cov, 0.0, 1.0) * 0.9;
}

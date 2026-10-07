shader_type spatial;
// Tile hover frame for the live client: unshaded, drawn over everything (no depth test) so the
// cursor stays readable behind tall buildings. `tint` is the tonemap-compensated linear colour.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled;

uniform vec3 tint = vec3(1.0);
uniform float alpha = 0.6;

void fragment() {
	ALBEDO = tint;
	ALPHA = alpha * COLOR.a;
}

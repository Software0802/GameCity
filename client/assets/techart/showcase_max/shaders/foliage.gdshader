shader_type spatial;
// Procedural leaf canopy: noise-cut leaf clumps over displaced blobs, baked vertex AO colour,
// translucent backlight. COLOR = vertex AO colour * per-instance tint.
render_mode cull_disabled;

#include "res://client/assets/techart/showcase_max/shaders/sc_common.gdshaderinc"

uniform float leaf_cut = 0.30;
uniform vec2 leaf_freq = vec2(30.0, 22.0);
uniform float backlight = 0.45;
varying vec4 v_col;
varying vec3 v_wpos;

void vertex() {
	v_col = COLOR;
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// gentle wind-free breathing offset keeps silhouettes from being perfectly smooth
	VERTEX += NORMAL * (sc_vnoise(v_wpos.xz * 1.7 + v_wpos.y) - 0.5) * 0.10;
}

void fragment() {
	float n1 = sc_vnoise(UV * leaf_freq);
	float n2 = sc_vnoise(UV * leaf_freq * 2.3 + 7.1);
	float leaf = n1 * 0.62 + n2 * 0.38;
	float rim = pow(1.0 - abs(dot(NORMAL, VIEW)), 2.0) * 0.14;
	if (leaf - leaf_cut - rim < 0.0) {
		discard;
	}
	vec3 col = v_col.rgb * (0.7 + 0.6 * leaf);
	ALBEDO = col;
	ROUGHNESS = 0.68;
	SPECULAR = 0.25;
	BACKLIGHT = col * backlight;
}

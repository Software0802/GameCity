shader_type spatial;
// Generic Poly Haven PBR (albedo / ARM / GL normal) with anti-tiling, macro variation, optional wetness
// and a curb band driven by UV2.x (distance from the curb in metres). UV is in metres.

#include "res://client/assets/techart/showcase_max/shaders/sc_common.gdshaderinc"

uniform sampler2D t_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D t_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D t_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float uv_m = 2.0;
uniform vec3 tint : source_color = vec3(1.0);
uniform float tint_var = 0.12;
uniform float macro_scale = 0.05;
uniform float normal_scale = 1.0;
uniform float rough_mul = 1.0;
uniform float rough_add = 0.0;
uniform float ao_strength = 1.0;
uniform float metallic_val = 0.0;
uniform float wet = 0.0;
uniform float antitile = 1.0;
uniform float curb_band_w = 0.0;
uniform vec3 curb_col : source_color = vec3(0.62, 0.61, 0.58);
uniform float dirt_edge = 0.0;      // darkens by UV2.y (distance from lot edge)
uniform vec3 grass_tint : source_color = vec3(1.0);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = UV / uv_m;
	float wmix = antitile * smoothstep(0.3, 0.7, sc_vnoise(wpos.xz * 0.11 + 3.7));
	vec4 al = sc_tex_nt(t_albedo, uv, wmix);
	vec4 arm = sc_tex_nt(t_arm, uv, wmix);
	vec3 nm = sc_nor_nt(t_nor, uv, wmix);
	float macro = sc_fbm(wpos.xz * macro_scale) * 2.0 - 1.0;
	float fine = sc_vnoise(wpos.xz * 0.9) * 2.0 - 1.0;
	vec3 col = al.rgb * tint * (1.0 + macro * tint_var + fine * tint_var * 0.25);
	float rough = clamp(arm.g * rough_mul + rough_add, 0.04, 1.0);
	float cb = 0.0;
	if (curb_band_w > 0.0) {
		cb = 1.0 - smoothstep(curb_band_w - 0.03, curb_band_w, UV2.x);
		col = mix(col, curb_col * (0.85 + 0.3 * al.g), cb);
		rough = mix(rough, 0.75, cb);
	}
	if (dirt_edge > 0.0) {
		col *= 1.0 - dirt_edge * (1.0 - smoothstep(0.0, 0.7, UV2.y)) * 0.45;
	}
	float puddle = smoothstep(0.52, 0.72, sc_fbm(wpos.xz * 0.28 + 11.0));
	float wf = wet * (0.45 + 0.55 * puddle);
	col *= 1.0 - 0.38 * wf;
	rough = mix(rough, 0.07, wf);
	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = metallic_val;
	AO = mix(1.0, arm.r, ao_strength);
	AO_LIGHT_AFFECT = 0.6;
	NORMAL_MAP = mix(vec3(0.5, 0.5, 1.0), nm, (1.0 - 0.8 * wf) * (1.0 - 0.7 * cb));
	NORMAL_MAP_DEPTH = normal_scale;
}

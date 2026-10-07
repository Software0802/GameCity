shader_type spatial;
// Carriageway: Poly Haven asphalt + analytic lane paint, wear, wheel tracks, patches, manholes, crosswalks.
// COLOR.r = kind (0 segment, 1 junction), COLOR.g = segment length / 64 or arm mask / 15,
// COLOR.b = end flags / 3 (1 stop line at start, 2 at end), COLOR.a = centre style (0 dashed white, 1 double yellow, 0.5 none).
// UV = world xz metres. UV2 = segment (along, across, +across is the right-hand side for +along travel)
// or junction (x, z) local metres from the corner.

#include "res://client/assets/techart/showcase_max/shaders/sc_common.gdshaderinc"

uniform sampler2D t_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D t_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D t_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float uv_m = 3.0;
uniform float half_w = 4.5;
uniform float half_row = 7.3;
uniform float park_w = 2.0;
uniform float wet = 0.0;
uniform float paint_wear = 0.55;
uniform vec3 tint : source_color = vec3(0.9, 0.9, 0.92);
uniform vec3 paint_white : source_color = vec3(0.86, 0.86, 0.82);
uniform vec3 paint_yellow : source_color = vec3(0.92, 0.70, 0.12);

varying vec3 wpos;
varying vec4 vcol;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vcol = COLOR;
}

float bit(float mask, float b) {
	return mod(floor(mask / b), 2.0) > 0.5 ? 1.0 : 0.0;
}

float line_h(float t, float c, float w, float px) {
	// horizontal band centred at c, width w
	return sc_aa_step(c - w * 0.5, t, px) * sc_aa_step(t, c + w * 0.5, px);
}

void fragment() {
	vec2 uv = UV / uv_m;
	float wmix = smoothstep(0.3, 0.7, sc_vnoise(wpos.xz * 0.09 + 5.1));
	vec4 al = sc_tex_nt(t_albedo, uv, wmix);
	vec4 arm = sc_tex_nt(t_arm, uv, wmix);
	vec3 nm = sc_nor_nt(t_nor, uv, wmix);
	float macro = sc_fbm(wpos.xz * 0.06) * 2.0 - 1.0;
	vec3 col = al.rgb * tint * (1.0 + macro * 0.14);
	float rough = clamp(arm.g * 1.0, 0.35, 1.0);
	float paint_a = 0.0;
	vec3 paint_c = paint_white;
	float px = max(fwidth(UV2.x) + fwidth(UV2.y), 0.0005);
	float kind = vcol.r;

	float gloss_track = 0.0;
	float dirt = 0.0;
	float manhole = 0.0;
	float patch_m = 0.0;
	vec2 loc = UV2;

	if (kind < 0.5) {
		float a = loc.x;
		float t = loc.y;
		float L = vcol.g * 64.0;
		float at = abs(t);
		float flags = floor(vcol.b * 3.0 + 0.5);
		// wheel tracks (polished, darker) in the two travel lanes (|t| in 0..2.5)
		float lane_c = 1.25;
		float tr = exp(-pow((at - (lane_c - 0.72)) / 0.26, 2.0)) + exp(-pow((at - (lane_c + 0.72)) / 0.26, 2.0));
		tr *= 0.55 + 0.45 * sc_vnoise(vec2(a * 0.35, t * 2.0));
		gloss_track = tr * step(at, half_w - park_w + 0.1);
		col *= 1.0 - 0.14 * gloss_track;
		rough = mix(rough, rough * 0.78, gloss_track);
		// gutter: dirt and sand along the curb
		float gut = smoothstep(half_w - 0.9, half_w - 0.05, at);
		float gn = sc_fbm(vec2(a * 0.7, t * 3.0));
		dirt = gut * (0.5 + 0.5 * gn);
		col = mix(col, col * vec3(0.78, 0.74, 0.68), dirt * 0.8);
		// repair patches per 22 m cell
		float cell = floor(a / 22.0);
		float hp = sc_hash21(vec2(cell, floor(wpos.x * 0.001) + floor(wpos.z * 0.001) * 7.0 + 3.0));
		float hp2 = sc_hash21(vec2(cell + 11.0, hp * 40.0));
		if (hp > 0.5) {
			float ca = (cell + 0.2 + 0.6 * hp2) * 22.0;
			float ct = (hp2 > 0.5 ? 1.25 : -1.25) + (hp - 0.75) * 0.6;
			vec2 d = abs(vec2(a - ca, t - ct)) - vec2(1.7 + 1.4 * hp2, 0.65 + 0.3 * hp);
			float m = 1.0 - sc_aa_step(0.0, max(d.x, d.y), px * 1.5);
			patch_m = m;
			col *= mix(1.0, 0.72, m);
			rough = mix(rough, 0.55, m);
		}
		// manholes
		float mc = floor((a + 7.0) / 24.0);
		float hm = sc_hash21(vec2(mc, 5.0 + floor(wpos.x * 0.01) + floor(wpos.z * 0.01) * 3.0));
		if (hm > 0.35) {
			float ma = (mc + 0.5) * 24.0 - 7.0 + (hm - 0.7) * 4.0;
			float mt = (hm > 0.7 ? 1.2 : -1.2);
			float dm = length(vec2(a - ma, t - mt));
			float mm = 1.0 - sc_aa_step(0.34, dm, px * 1.5);
			float ring = sc_aa_step(0.26, dm, px) * mm;
			float cross_ = max(line_h(fract((a - ma) * 6.0 + 0.5) - 0.5, 0.0, 0.18, 0.1), line_h(fract((t - mt) * 6.0 + 0.5) - 0.5, 0.0, 0.18, 0.1));
			manhole = mm;
			vec3 iron = vec3(0.06, 0.055, 0.05) * (0.8 + 0.5 * cross_) + ring * vec3(0.05);
			col = mix(col, iron, mm);
			rough = mix(rough, 0.42, mm);
		}
		// --- paint ---
		// parking-lane boundary (solid white)
		float edge_ln = line_h(at, half_w - park_w, 0.13, px);
		// parking stall ticks every 6 m inside the parking lane
		float stall_t = sc_aa_step(half_w - park_w, at, px) * sc_aa_step(at, half_w - park_w + 0.45, px);
		float stall_a = line_h(fract(a / 6.0 + 0.5) - 0.5, 0.0, 0.1 / 6.0, px / 6.0);
		float stall = stall_t * stall_a * step(1.5, a) * step(a, L - 1.5);
		// centre line
		float cstyle = vcol.a;
		float cen = 0.0;
		vec3 cen_c = paint_white;
		if (cstyle > 0.75) {
			cen = max(line_h(t, -0.11, 0.1, px), line_h(t, 0.11, 0.1, px));
			cen_c = paint_yellow;
		} else if (cstyle < 0.25) {
			float dash = step(fract((a - 0.5) / 6.0), 0.5);
			cen = line_h(t, 0.0, 0.12, px) * dash;
		}
		// stop lines (approach lane only)
		float stop = 0.0;
		float s_start = (mod(flags, 2.0) > 0.5) ? 1.0 : 0.0;
		float s_end = (flags > 1.5) ? 1.0 : 0.0;
		// lane on the approach to the start end is t < 0, to the end is t > 0 (right-hand traffic)
		stop += s_start * line_h(a, 1.3, 0.4, px) * (1.0 - sc_aa_step(0.0, t, px)) * sc_aa_step(-(half_w - park_w), t, px);
		stop += s_end * line_h(a, L - 1.3, 0.4, px) * sc_aa_step(0.0, t, px) * sc_aa_step(t, half_w - park_w, px);
		float pa = max(max(edge_ln, stall), max(cen, clamp(stop, 0.0, 1.0)));
		paint_a = pa;
		paint_c = (cen > max(edge_ln, max(stall, stop)) && cstyle > 0.75) ? cen_c : paint_white;
	} else {
		// junction: crosswalks on arms of a 3+ way junction
		float mask = floor(vcol.g * 15.0 + 0.5);
		float inN = bit(mask, 1.0);
		float inE = bit(mask, 2.0);
		float inS = bit(mask, 4.0);
		float inW = bit(mask, 8.0);
		float arms = inN + inE + inS + inW;
		float xw = 0.0;
		if (arms > 2.5) {
			float zb0 = half_w + 0.35;
			float zb1 = half_row - 0.3;
			// N arm: z in [-row, -w]
			float bar_x = step(fract((loc.x + half_w) / 1.0), 0.52) * step(abs(loc.x), half_w - 0.25);
			float bar_z = step(fract((loc.y + half_w) / 1.0), 0.52) * step(abs(loc.y), half_w - 0.25);
			float zN = inN * bar_x * sc_aa_step(zb0, -loc.y, px) * sc_aa_step(-loc.y, zb1, px);
			float zS = inS * bar_x * sc_aa_step(zb0, loc.y, px) * sc_aa_step(loc.y, zb1, px);
			float xE = inE * bar_z * sc_aa_step(zb0, loc.x, px) * sc_aa_step(loc.x, zb1, px);
			float xW = inW * bar_z * sc_aa_step(zb0, -loc.x, px) * sc_aa_step(-loc.x, zb1, px);
			xw = max(max(zN, zS), max(xE, xW));
		}
		paint_a = xw;
		float gn = sc_fbm(loc * 0.9);
		dirt = smoothstep(0.55, 0.9, gn) * 0.35;
		col *= 1.0 - 0.1 * dirt;
		float mt = (sc_fbm(wpos.xz * 0.5) - 0.5);
		col *= 1.0 + mt * 0.12;
	}

	// paint wear
	float wear = smoothstep(0.30, 0.62, sc_fbm(wpos.xz * vec2(3.2, 3.2) + 7.0) + 0.25 * sc_vnoise(wpos.xz * 17.0));
	float pa_w = paint_a * mix(1.0, wear, paint_wear);
	// wetness (dusk preset)
	float puddle = smoothstep(0.50, 0.70, sc_fbm(wpos.xz * 0.22 + 11.0) + 0.1 * gloss_track);
	float wf = wet * (0.50 + 0.50 * puddle);
	col = mix(col, paint_c, pa_w * 0.92);
	rough = mix(rough, 0.62, pa_w);
	col *= 1.0 - 0.36 * wf;
	rough = mix(rough, 0.06, wf);
	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = mix(0.0, 0.75, manhole);
	SPECULAR = 0.5;
	AO = mix(1.0, arm.r, 0.8);
	AO_LIGHT_AFFECT = 0.5;
	float flat_ = clamp(pa_w * 0.7 + manhole * 0.9 + patch_m * 0.3 + wf * 0.75, 0.0, 1.0);
	NORMAL_MAP = mix(nm, vec3(0.5, 0.5, 1.0), flat_);
	NORMAL_MAP_DEPTH = 0.8;
}

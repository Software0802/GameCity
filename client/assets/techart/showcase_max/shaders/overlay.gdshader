shader_type spatial;
// Game overlay layer: faction outlines and curtains, zone lot plates, power coverage, congestion pulse,
// tile grid. Unshaded on purpose so the palette hex values stay readable; never touches world albedo.
// mode 0 flat colour, 1 curtain (alpha fades with UV.y), 2 congestion pulse (UV.x runs along the edge),
// 3 power field (soft dotted fill), 4 grid lines (world space), 5 ring (UV.x around, dashed)
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

#include "res://client/assets/techart/showcase_max/shaders/sc_common.gdshaderinc"

uniform int mode = 0;
uniform float gain = 1.0;
uniform float night = 0.0;
uniform float pulse_phase = 0.0;
uniform float tile_pitch = 30.0;
uniform vec2 grid_origin = vec2(0.0);
uniform float grid_alpha = 0.14;
uniform float block_every = 8.0;
uniform float fade_dist = 0.0;
uniform vec3 pal[16];   // tonemap-compensated palette, set per preset by world.gd

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 c = COLOR;
	vec3 rgb = pal[int(c.r * 15.0 + 0.5)] * gain;
	if (mode == 4) { rgb = c.rgb; }
	float a = c.a;
	if (mode == 1) {
		float g = 1.0 - clamp(UV.y, 0.0, 1.0);
		a *= g * g;
		// fine vertical shimmer lines
		a *= 0.8 + 0.2 * step(0.5, fract(UV.x * 0.8));
	} else if (mode == 2) {
		// travelling bright band along the edge; c.a carries congestion strength
		float t = UV.x;
		float band = 0.5 + 0.5 * sin((t * 1.0 - pulse_phase) * 6.2831853 * 3.0);
		float core = 1.0 - clamp(abs(UV.y - 0.5) * 2.0, 0.0, 1.0);
		a = clamp(a * (0.55 + 0.6 * band) * (0.35 + 0.9 * core), 0.0, 1.0);
		rgb *= 1.0 + 0.8 * band * c.a;
	} else if (mode == 3) {
		a *= 0.8 + 0.2 * sc_vnoise(wpos.xz * 0.05);
	} else if (mode == 4) {
		vec2 q = (wpos.xz - grid_origin) / tile_pitch;
		vec2 fw = fwidth(q) * 1.2;
		vec2 gl = abs(fract(q - 0.5) - 0.5) / max(fw, vec2(1e-4));
		float line = 1.0 - min(min(gl.x, gl.y), 1.0);
		vec2 qb = q / block_every;
		vec2 fb = fwidth(qb) * 2.2;
		vec2 gb = abs(fract(qb - 0.5) - 0.5) / max(fb, vec2(1e-4));
		float bl = 1.0 - min(min(gb.x, gb.y), 1.0);
		a = max(line * grid_alpha, bl * grid_alpha * 3.0);
		rgb = mix(vec3(0.9, 0.95, 1.0), vec3(1.0, 0.95, 0.7), bl);
	} else if (mode == 5) {
		float dash = step(0.5, fract(UV.x * 0.5));
		float core = 1.0 - clamp(abs(UV.y - 0.5) * 2.0, 0.0, 1.0);
		a *= (0.55 + 0.45 * dash) * (0.4 + 0.8 * core);
	}
	ALBEDO = rgb;
	ALPHA = clamp(a, 0.0, 1.0);
}

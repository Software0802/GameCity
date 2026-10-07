shader_type spatial;
// Live-client game overlay (M4), adapted from showcase_max/shaders/overlay.gdshader.
// Faction outlines and curtains, zone lot plates and frames, power coverage, pollution haze,
// congestion pulse, roof badges, region summaries. Unshaded on purpose so the palette hex values
// stay readable (docs/briefs/art-visual-source.md); never touches world albedo.
//   mode 0 flat colour from the palette slot in COLOR.r
//   mode 1 curtain (alpha fades with UV.y)
//   mode 2 congestion pulse (UV.x runs along the edge, COLOR.a = strength)
//   mode 3 field (soft noisy fill: power coverage, pollution haze)
//   mode 6 direct: COLOR.rgb is an already tonemap-compensated linear colour / 2 (summaries)
// pal[] holds the tonemap-compensated palette (see live_palette.gd); slot = COLOR.r * 15.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

#include "res://client/assets/techart/showcase_max/shaders/sc_common.gdshaderinc"

uniform int mode = 0;
uniform float gain = 1.0;
uniform float pulse_phase = 0.0;
uniform vec3 pal[16];

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 c = COLOR;
	vec3 rgb = pal[int(c.r * 15.0 + 0.5)] * gain;
	float a = c.a;
	if (mode == 1) {
		float g = 1.0 - clamp(UV.y, 0.0, 1.0);
		a *= g * g;
		a *= 0.8 + 0.2 * step(0.5, fract(UV.x * 0.8));
	} else if (mode == 2) {
		float t = UV.x;
		float band = 0.5 + 0.5 * sin((t * 1.0 - pulse_phase) * 6.2831853 * 3.0);
		float core = 1.0 - clamp(abs(UV.y - 0.5) * 2.0, 0.0, 1.0);
		a = clamp(a * (0.55 + 0.6 * band) * (0.35 + 0.9 * core), 0.0, 1.0);
		rgb *= 1.0 + 0.8 * band * c.a;
	} else if (mode == 3) {
		a *= 0.8 + 0.2 * sc_vnoise(wpos.xz * 0.05);
	} else if (mode == 6) {
		rgb = c.rgb * 2.0 * gain;
	}
	ALBEDO = rgb;
	ALPHA = clamp(a, 0.0, 1.0);
}

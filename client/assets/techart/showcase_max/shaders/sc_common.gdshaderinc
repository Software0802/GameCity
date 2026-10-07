// Shared helpers for showcase_max shaders.

float sc_hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

float sc_hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 sc_hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

float sc_vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = sc_hash21(i);
	float b = sc_hash21(i + vec2(1.0, 0.0));
	float c = sc_hash21(i + vec2(0.0, 1.0));
	float d = sc_hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float sc_fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * sc_vnoise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}

// Rotation used for anti-tiling second sample.
const mat2 SC_ROT = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));

// Anti-tiled sample: blend two differently rotated/scaled lookups by low-frequency noise.
vec4 sc_tex_nt(sampler2D t, vec2 uv, float w) {
	vec2 uvb = SC_ROT * uv * 0.83 + vec2(0.37, 0.61);
	return mix(texture(t, uv), texture(t, uvb), w);
}

vec3 sc_nor_nt(sampler2D t, vec2 uv, float w) {
	vec2 uvb = SC_ROT * uv * 0.83 + vec2(0.37, 0.61);
	vec3 na = texture(t, uv).xyz * 2.0 - 1.0;
	vec3 nb = texture(t, uvb).xyz * 2.0 - 1.0;
	// rotate the second normal's xy back into uv space (inverse of SC_ROT)
	nb.xy = transpose(SC_ROT) * nb.xy;
	vec3 n = mix(na, nb, w);
	return normalize(n) * 0.5 + 0.5;
}

float sc_aa_step(float edge, float x, float px) {
	return clamp((x - edge) / max(px, 1e-5) + 0.5, 0.0, 1.0);
}

// Soft rectangle mask (1 inside) in 2D with anti-aliasing width px.
float sc_rect(vec2 p, vec2 lo, vec2 hi, float px) {
	vec2 a = vec2(sc_aa_step(lo.x, p.x, px), sc_aa_step(lo.y, p.y, px));
	vec2 b = vec2(sc_aa_step(p.x, hi.x, px), sc_aa_step(p.y, hi.y, px));
	return a.x * a.y * b.x * b.y;
}

shader_type sky;
// Poly Haven equirect HDRI with a luminance clamp. The stock PanoramaSkyMaterial feeds the raw sun disc
// (values in the tens of thousands) into the radiance map, so every rough surface reflects a second, far
// stronger sun on top of the DirectionalLight3D. The visible background keeps a (much higher) clamp so the
// sun still reads in cinematic shots; the radiance cubemap pass gets the tight one.
uniform sampler2D hdri : filter_linear, repeat_disable;
uniform float energy = 1.0;
uniform float radiance_energy = 0.55;   // scales only the radiance cubemap (ambient + reflections); ambient_light_energy does not scale a sky source
uniform float max_lum_view = 40.0;
uniform float max_lum_radiance = 3.0;
uniform vec3 tint : source_color = vec3(1.0);
uniform vec3 ground_col : source_color = vec3(0.16, 0.17, 0.17);
uniform float ground_mix = 0.85;
uniform float ground_horizon = 0.04;

void sky() {
	vec3 dir = normalize(EYEDIR);
	vec2 uv = vec2(atan(dir.x, -dir.z) / TAU + 0.5, acos(clamp(dir.y, -1.0, 1.0)) / PI);
	vec3 c = textureLod(hdri, uv, 0.0).rgb * energy * tint * (AT_CUBEMAP_PASS ? radiance_energy : 1.0);
	float cap = AT_CUBEMAP_PASS ? max_lum_radiance : max_lum_view;
	float l = max(c.r, max(c.g, c.b));
	c *= min(1.0, cap / max(l, 1e-4));
	// below the horizon the pure-sky HDRI mirrors the sky; swap in a dim ground tone so ambient and
	// reflections from below do not pretend the street is a bright lake
	float below = smoothstep(ground_horizon, -ground_horizon * 2.0, dir.y);
	c = mix(c, ground_col * (0.6 + 0.4 * clamp(dot(c, vec3(0.33)), 0.0, 1.0)), below * ground_mix);
	COLOR = c;
}

shader_type spatial;
// Vertex-coloured emitter for signs, lamp heads, beacons. Day: faint glow. Night: strong emission (bloom source).
uniform float night = 0.0;
uniform float day_emit = 0.12;
uniform float night_emit = 3.2;
uniform float rough = 0.45;

void fragment() {
	ALBEDO = COLOR.rgb * 0.6;
	ROUGHNESS = rough;
	EMISSION = COLOR.rgb * mix(day_emit, night_emit, night) * max(COLOR.a, 0.0);
}

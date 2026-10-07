shader_type spatial;
// Procedural facade: Poly Haven wall PBR + analytic windows / frames / sills / doors / curtain wall,
// interior-mapped rooms behind the glass, emissive lit windows at dusk, soot and rain streaks.
//
// Vertex attributes (built by building_builder.gd):
//   UV   = (u metres along the wall, -height metres from the wall base)
//   UV2  = (wall width, wall height) in metres
//   COLOR  = (seed, floor height / 8, bay width / 8, lit probability)
//   CUSTOM0 = (front door flag, parapet height / 4, door bay index, variant)

#include "res://client/assets/techart/showcase_max/shaders/sc_common.gdshaderinc"

uniform int style = 0;                // 0 punched (R), 1 ribbon (C), 2 curtain wall (C tier 2), 3 industrial (I)
uniform sampler2D wall_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D wall_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D wall_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float wall_m = 1.6;
uniform vec3 wall_tint : source_color = vec3(1.0);
uniform float tint_var = 0.10;
uniform sampler2D base_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D base_arm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D base_nor : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float base_m = 2.0;
uniform vec3 base_tint : source_color = vec3(0.85);
uniform float base_h = 0.9;
uniform float normal_scale = 1.0;
uniform float ground_scale = 1.25;
uniform float win_frac = 0.42;
uniform float win_h = 1.5;
uniform float sill_h = 0.95;
uniform float frame_w = 0.07;
uniform vec3 frame_col : source_color = vec3(0.86, 0.86, 0.84);
uniform vec3 glass_col : source_color = vec3(0.05, 0.075, 0.1);
uniform float glass_metal = 0.0;
uniform float glass_rough = 0.05;
uniform float night = 0.0;
uniform bool use_clearcoat = true;
uniform float emit_gain = 0.85;
uniform float interior_day = 0.14;
uniform float room_depth = 4.2;
uniform float dirt_amount = 0.5;
uniform vec3 band_col : source_color = vec3(0.8);

varying vec4 v_col;
varying vec4 v_c0;
varying vec2 v_wh;
varying vec3 v_wpos;

void vertex() {
	v_col = COLOR;
	v_c0 = CUSTOM0;
	v_wh = UV2;
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

vec3 room_palette(float r) {
	if (r < 0.2) return vec3(0.82, 0.78, 0.70);
	if (r < 0.4) return vec3(0.78, 0.66, 0.50);
	if (r < 0.6) return vec3(0.62, 0.70, 0.78);
	if (r < 0.8) return vec3(0.74, 0.74, 0.72);
	return vec3(0.80, 0.58, 0.52);
}

// Interior mapping: box room behind the window, returns unlit surface colour and brightness factor.
vec3 interior(vec2 pc, vec3 vt, float bw, float fh, float rid, float lit, vec3 lamp_col, float night_k, bool office) {
	vec3 dir = normalize(vec3(-vt.x, -vt.y, max(vt.z, 0.05)));
	vec3 p0 = vec3(pc.x, pc.y, 0.0);
	float tx = dir.x > 1e-4 ? (bw - p0.x) / dir.x : (dir.x < -1e-4 ? -p0.x / dir.x : 1e5);
	float ty = dir.y > 1e-4 ? (fh - p0.y) / dir.y : (dir.y < -1e-4 ? -p0.y / dir.y : 1e5);
	float tz = room_depth / dir.z;
	float t = min(tz, min(tx, ty));
	vec3 hit = p0 + dir * t;
	vec3 wallc = room_palette(sc_hash11(rid * 3.17));
	if (office) {
		float g = 0.62 + 0.25 * sc_hash11(rid * 3.17);
		wallc = vec3(g, g * 1.0, g * 1.02);
	}
	vec3 col;
	vec3 nrm;
	if (t == tz) {
		col = wallc;
		nrm = vec3(0.0, 0.0, -1.0);
		// furniture silhouette and a framed picture on the back wall
		float fx0 = sc_hash11(rid * 7.1) * bw * 0.5;
		float fw = 0.8 + sc_hash11(rid * 5.3) * bw * 0.45;
		float fhh = 0.55 + sc_hash11(rid * 2.9) * 0.5;
		if (hit.x > fx0 && hit.x < fx0 + fw && hit.y < fhh) col = col * 0.35;
		float px0 = bw * (0.3 + 0.3 * sc_hash11(rid * 1.3));
		if (abs(hit.x - px0) < 0.35 && abs(hit.y - 1.5) < 0.25) col = mix(col, vec3(0.35, 0.45, 0.55), 0.8);
	} else if (t == ty) {
		if (dir.y > 0.0) { col = vec3(0.90, 0.90, 0.88); nrm = vec3(0.0, -1.0, 0.0); }
		else { col = vec3(0.34, 0.24, 0.16) * (0.8 + 0.4 * sc_vnoise(hit.xz * 3.0 + rid)); nrm = vec3(0.0, 1.0, 0.0); }
	} else {
		col = wallc * 0.92;
		nrm = vec3(dir.x > 0.0 ? -1.0 : 1.0, 0.0, 0.0);
	}
	vec3 lamp = vec3(bw * 0.5, fh - 0.3, room_depth * 0.45);
	vec3 to_l = lamp - hit;
	float d2 = dot(to_l, to_l);
	float ndl = clamp(dot(nrm, normalize(to_l)) * 0.7 + 0.3, 0.1, 1.0);
	float lamp_i = ndl / (1.0 + 0.10 * d2);
	vec3 lit_col = col * lamp_col * lamp_i * 1.7;
	vec3 day_col = col * interior_day * (0.6 + 0.4 * (1.0 - t / (room_depth + 2.0)));
	return mix(day_col, lit_col, lit * night_k);
}

void fragment() {
	float u = UV.x;
	float h = -UV.y;
	float W = v_wh.x;
	float Ht = v_wh.y;
	float seed = v_col.r;
	float fh = max(v_col.g * 8.0, 2.0);
	float bay = max(v_col.b * 8.0, 1.0);
	float lit_p = v_col.a;
	float door_flag = v_c0.x;
	float parapet = v_c0.y * 4.0;
	float door_bay = v_c0.z;
	float variant = v_c0.w;
	float px = max(fwidth(u) + fwidth(h), 0.0004);

	float nbf = max(1.0, floor(W / bay + 0.5));
	float bw = W / nbf;
	float bi = clamp(floor(u / bw), 0.0, nbf - 1.0);
	float bu = u - bi * bw;
	float gh = fh * ground_scale;
	float fi;
	float fv;
	float fcur;
	if (h < gh) {
		fi = 0.0;
		fv = h;
		fcur = gh;
	} else {
		float hh = h - gh;
		fi = 1.0 + floor(hh / fh);
		fv = hh - (fi - 1.0) * fh;
		fcur = fh;
	}
	vec2 cid = vec2(bi, fi) + vec2(seed * 97.0, seed * 31.0);
	float r1 = sc_hash21(cid);
	float r2 = sc_hash21(cid + 7.31);
	float r3 = sc_hash21(cid + 19.7);
	bool is_ground = fi < 0.5;
	bool in_top = h > Ht - parapet;
	bool is_door_bay = is_ground && door_flag > 0.5 && abs(bi - door_bay) < 0.5;

	// ---- opening rectangle in bay-floor local metres (x across the bay, y above the floor)
	float ww = bw * win_frac;
	float wh = win_h;
	float sill = sill_h;
	float is_glass_curtain = 0.0;
	if (style == 0) {
		if (is_ground) { sill = 0.7; wh = 1.45; }
	} else if (style == 1) {
		ww = bw - 0.22;
		sill = 0.9;
		wh = fcur - sill - 0.62;
		if (is_ground) { sill = 0.45; wh = fcur - sill - 0.55; }
	} else if (style == 2) {
		ww = bw - 0.10;
		sill = 1.0;
		wh = fcur - sill - 0.12;
		if (is_ground) { sill = 0.12; wh = fcur - sill - 0.25; }
		is_glass_curtain = 1.0;
	} else {
		// industrial: strip windows high on the wall, roller doors on the ground floor
		ww = bw * 0.62;
		sill = fcur - 1.75;
		wh = 1.05;
		if (is_ground) {
			sill = 0.0;
			wh = 0.0;
		}
	}
	if (in_top) { wh = 0.0; }
	vec2 pc = vec2(bu, fv);
	vec2 ctr = vec2(bw * 0.5, sill + wh * 0.5);
	vec2 half_o = vec2(ww * 0.5, wh * 0.5);
	float m_open = (wh > 0.01) ? sc_rect(pc, ctr - half_o, ctr + half_o, px) : 0.0;
	float fw = frame_w;
	if (style == 2) fw = 0.04;
	float m_glass = (wh > 0.01) ? sc_rect(pc, ctr - half_o + fw, ctr + half_o - fw, px) : 0.0;
	float m_frame = clamp(m_open - m_glass, 0.0, 1.0);

	// industrial door (large roller) and generic entrance door
	float m_door = 0.0;
	float m_door_glass = 0.0;
	if (is_door_bay) {
		float dw = (style == 3) ? 3.2 : min(bw * 0.55, 1.9);
		float dh = (style == 3) ? 3.6 : min(fcur - 0.35, 2.55);
		vec2 dc = vec2(bw * 0.5, dh * 0.5);
		m_door = sc_rect(pc, dc - vec2(dw * 0.5, dh * 0.5), dc + vec2(dw * 0.5, dh * 0.5), px);
		m_door_glass = sc_rect(pc, dc - vec2(dw * 0.5 - 0.08, dh * 0.5 - 0.08), dc + vec2(dw * 0.5 - 0.08, dh * 0.5 - 0.12), px);
		m_open = max(m_open * 0.0, m_door);
	}
	if (style == 3 && is_ground && !is_door_bay) {
		// roller doors every other bay, plus small personnel door
		float doorsel = step(0.5, fract((bi + variant * 3.0) * 0.5));
		float dw = 3.0;
		float dh = 3.4;
		vec2 dc = vec2(bw * 0.5, dh * 0.5);
		float rd = sc_rect(pc, dc - vec2(dw * 0.5, dh * 0.5), dc + vec2(dw * 0.5, dh * 0.5), px) * doorsel;
		m_door = max(m_door, rd);
	}

	// ---- wall surface
	vec2 tuv = UV / wall_m;
	vec3 wa = texture(wall_albedo, tuv).rgb;
	vec4 warm = texture(wall_arm, tuv);
	vec3 wn = texture(wall_nor, tuv).xyz;
	float macro = sc_fbm(vec2(u, h) * 0.18 + seed * 40.0) * 2.0 - 1.0;
	vec3 wall_c = wa * wall_tint * (1.0 + macro * tint_var);
	float wall_r = clamp(warm.g, 0.15, 1.0);
	float wall_ao = warm.r;
	vec3 nmap = wn;
	// plinth / ground-floor cladding
	float in_base = 1.0 - sc_aa_step(base_h, h, px);
	if (style == 1 && is_ground) in_base = max(in_base, 1.0);
	{
		vec2 buv = UV / base_m;
		vec3 ba = texture(base_albedo, buv).rgb * base_tint;
		vec4 bm = texture(base_arm, buv);
		vec3 bn = texture(base_nor, buv).xyz;
		// industrial and curtain buildings only use the plinth; ribbon buildings clad the whole ground floor
		float bsel = in_base;
		wall_c = mix(wall_c, ba, bsel);
		wall_r = mix(wall_r, clamp(bm.g, 0.15, 1.0), bsel);
		wall_ao = mix(wall_ao, bm.r, bsel);
		nmap = mix(nmap, bn, bsel);
	}
	// horizontal floor bands (string courses) on punched facades; spandrel darkening on ribbon / curtain
	float band = 0.0;
	if (style == 0 && !is_ground) {
		band = 1.0 - sc_aa_step(0.16, fv, px);
		wall_c = mix(wall_c, wall_c * 0.78, band * 0.55);
	}
	if (style == 1 && !is_ground) {
		float sp = (1.0 - sc_aa_step(sill - 0.02, fv, px)) + sc_aa_step(sill + wh + 0.02, fv, px);
		wall_c = mix(wall_c, band_col * (0.9 + 0.2 * macro), clamp(sp, 0.0, 1.0) * 0.5);
	}
	if (style == 2) {
		// opaque spandrel glass band at each slab
		float sp = 1.0 - sc_aa_step(sill, fv, px);
		wall_c = mix(wall_c, glass_col * 1.4, sp);
	}
	// cap / cornice line
	float cap = sc_aa_step(Ht - 0.14, h, px);
	wall_c = mix(wall_c, wall_c * 1.18, cap * 0.5);
	// ---- opening AO on the wall
	vec2 dq = max(abs(pc - ctr) - half_o, vec2(0.0));
	float dist_o = length(dq);
	// reveal bevel: tilt the wall normal toward the opening across a 7 cm band so frames catch light and shade
	if (wh > 0.01 && style != 2) {
		vec2 dv = pc - ctr;
		vec2 ov = abs(dv) - half_o;
		float inside = max(ov.x, ov.y);
		float band = (1.0 - sc_aa_step(0.0, inside, px)) * 0.0;
		float bevel = smoothstep(0.075, 0.0, inside) * step(0.0, inside);
		vec2 dirv = (ov.x > ov.y) ? vec2(sign(dv.x), 0.0) : vec2(0.0, sign(dv.y));
		// wall tangent space x = along u, y = up (v is -h): normal-map convention y up
		nmap.xy = mix(nmap.xy, nmap.xy - dirv * vec2(0.35, 0.35) * 0.5 + vec2(0.0), bevel);
	}
	float ao_open = (wh > 0.01) ? mix(0.55, 1.0, smoothstep(0.0, 0.28, dist_o)) : 1.0;
	// sill: lighter strip just below the opening with a shadow below it
	float sill_m = 0.0;
	if (style == 0 && wh > 0.01 && !in_top) {
		sill_m = sc_rect(pc, vec2(ctr.x - half_o.x - 0.07, sill - 0.12), vec2(ctr.x + half_o.x + 0.07, sill - 0.01), px);
		wall_c = mix(wall_c, band_col, sill_m * 0.85);
		ao_open *= mix(1.0, 0.75, smoothstep(0.0, 0.25, sill - 0.12 - pc.y) * (1.0 - smoothstep(0.25, 0.55, sill - 0.12 - pc.y)) * step(pc.y, sill - 0.12));
	}
	// ---- grime: ground soot + rain streaks
	float soot = (1.0 - smoothstep(0.0, 3.0, h)) * (0.5 + 0.5 * sc_vnoise(vec2(u * 0.9, h * 0.4)));
	float streak = smoothstep(0.55, 0.85, sc_vnoise(vec2(u * 7.0 + seed * 19.0, h * 0.25))) * smoothstep(0.0, 0.6, (sill - fv + 0.7)) * 0.5;
	float grime = clamp(soot * 0.6 + streak * 0.3, 0.0, 1.0) * dirt_amount;
	wall_c *= 1.0 - 0.45 * grime;
	wall_r = mix(wall_r, 0.95, grime * 0.5);

	// ---- compose
	vec3 albedo = wall_c;
	float rough = wall_r;
	float metal = 0.0;
	float spec = 0.5;
	float ao = wall_ao * ao_open;
	vec3 emis = vec3(0.0);
	vec3 nm = nmap;

	// frame
	vec3 fcol = frame_col * (0.85 + 0.3 * r2);
	if (style == 2) fcol = vec3(0.16, 0.18, 0.2);
	albedo = mix(albedo, fcol, m_frame);
	rough = mix(rough, 0.38, m_frame);
	metal = mix(metal, (style == 2 || style == 1) ? 0.75 : 0.1, m_frame);
	nm = mix(nm, vec3(0.5, 0.5, 1.0), m_frame);
	// glass with interior mapping
	if (m_glass > 0.002 || m_door_glass > 0.002) {
		float gm = max(m_glass, m_door_glass);
		vec3 vt = vec3(dot(VIEW, TANGENT), dot(VIEW, BINORMAL), dot(VIEW, NORMAL));
		bool curtain_spandrel = (style == 2 && fv < sill);
		float lit_sel = step(r1, lit_p);
		vec3 lamp_col = (style == 0) ? mix(vec3(1.0, 0.72, 0.42), vec3(1.0, 0.85, 0.62), r3) : mix(vec3(0.78, 0.88, 1.0), vec3(1.0, 0.92, 0.78), r3 * 0.6);
		if (style == 3) lamp_col = vec3(1.0, 0.9, 0.7);
		vec2 ipc = pc;
		if (m_door_glass > 0.5) ipc = vec2(pc.x, pc.y);
		vec3 room = interior(ipc, vt, bw, fcur, bi * 13.0 + fi * 5.0 + seed * 71.0, lit_sel, lamp_col, night, style != 0);
		// blinds / curtains: cover the top part of some windows
		float blind_on = step(0.55, r2) * (style == 2 ? 0.0 : 1.0);
		float bfrac = 0.25 + 0.6 * r3;
		float yb = (pc.y - (ctr.y - half_o.y)) / max(wh, 0.1);
		float blind = blind_on * step(1.0 - bfrac, yb);
		float slats = 0.85 + 0.15 * step(0.5, fract(pc.y * 14.0));
		vec3 blind_c = (style == 0 ? vec3(0.78, 0.74, 0.66) : vec3(0.72, 0.74, 0.76)) * slats;
		vec3 blind_emit = blind_c * mix(0.35, 3.0 * lit_sel, night * lit_sel) * mix(1.0, 0.8, 0.0);
		room = mix(room, blind_c * mix(interior_day * 2.2, 2.4 * lamp_col.r * lit_sel * night + interior_day * 1.2, night * lit_sel), blind);
		vec3 gcol = glass_col * (0.8 + 0.4 * r1);
		if (curtain_spandrel) { room = vec3(0.0); gcol = glass_col * 1.3; }
		if (m_door_glass > 0.5 && style != 3) { gcol = glass_col * 0.9; }
		albedo = mix(albedo, gcol, gm);
		rough = mix(rough, glass_rough, gm);
		metal = mix(metal, glass_metal, gm);
		spec = mix(spec, 0.9, gm);
		ao = mix(ao, mix(0.7, 1.0, 1.0), gm);
		nm = mix(nm, vec3(0.5, 0.5, 1.0), gm);
		emis = room * emit_gain * gm * (curtain_spandrel ? 0.0 : 1.0);
	}
	// doors
	if (m_door > 0.002 && style != 3 && m_door_glass < 0.5) {
		albedo = mix(albedo, vec3(0.12, 0.13, 0.15), m_door);
		metal = mix(metal, 0.6, m_door);
		rough = mix(rough, 0.35, m_door);
	}
	if (style == 3 && m_door > 0.002) {
		float ribs = 0.8 + 0.2 * step(0.5, fract(pc.y * 5.0));
		albedo = mix(albedo, vec3(0.55, 0.58, 0.6) * ribs, m_door);
		metal = mix(metal, 0.55, m_door);
		rough = mix(rough, 0.5, m_door);
		nm = mix(nm, vec3(0.5, 0.5, 1.0), m_door);
	}

	ALBEDO = albedo;
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = spec;
	// glass gets a clearcoat layer (sharp sky reflection over the interior-mapped room)
	float gcoat = max(m_glass, m_door_glass);
	if (use_clearcoat) {
		CLEARCOAT = gcoat;
		CLEARCOAT_ROUGHNESS = 0.03;
	}
	AO = ao;
	AO_LIGHT_AFFECT = 0.7;
	EMISSION = emis;
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = normal_scale;
}

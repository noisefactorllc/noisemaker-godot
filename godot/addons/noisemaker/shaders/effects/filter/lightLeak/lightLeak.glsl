#version 450
// filter/lightLeak — ported PIXEL-IDENTICALLY from wgsl/lightLeak.wgsl. A 6-point
// toroidal Voronoi colored-leak field with wormhole UV warp, distance-falloff bloom,
// screen blend, Chebyshev center mask, and a 4-neighbor "vaseline" softening, blended
// by alpha. Single render pass (progName "lightLeak").
//
// No-layout effect (lightLeak.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define <name> data[slot].comp` for the engine globals and
// every param uniform: alpha, color (vec3, 3 components), speed, seed. We use the bare
// names directly. Engine `time` used (bare). The vec3 `color` macro is passed into the
// Voronoi helper as `user_color` (mirrors the WGSL signature). Input texture at set 0,
// binding 1.
//
// COORDINATE NOTE: ported from WGSL (top-left, no Y-flip): uv = gl_FragCoord.xy /
// texSize for the leak pattern; integer texel fetches use ivec2(gl_FragCoord.xy). The
// reference's `+ tileOffset` / fullResolution global-UV remap is a tiling concern we do
// not reproduce (tileOffset=(0,0), fullResolution==texSize here). voronoiCell returns
// vec4(cell_color.rgb, squared_dist) like the WGSL. WGSL `select(...)` → ternary; WGSL
// `textureLoad` → `texelFetch`. No arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float LL_TAU = 6.28318530717958647692;
const int POINT_COUNT = 6;

uvec3 pcg(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v = v ^ (v >> uvec3(16u));
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

vec3 hash33(vec3 p) {
	uvec3 v = uvec3(
		uint(p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0),
		uint(p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0),
		uint(p.z >= 0.0 ? p.z * 2.0 : -p.z * 2.0 + 1.0)
	);
	uvec3 h = pcg(v);
	return vec3(
		float(h.x) / float(0xffffffffu),
		float(h.y) / float(0xffffffffu),
		float(h.z) / float(0xffffffffu)
	);
}

float luminance(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

// Voronoi: find nearest of 6 seed-based points (toroidal distance).
// Returns cell color in rgb and squared distance in w.
vec4 voronoiCell(vec2 uv, float seed_f, float t, vec3 user_color) {
	float best_dist = 1e9;
	int best_index = 0;
	float drift = 0.05;

	for (int i = 0; i < POINT_COUNT; i++) {
		vec3 s = vec3(seed_f, float(i) * 7.31, 0.0);
		vec2 base = hash33(s).xy;
		vec2 osc = vec2(
			sin(t * 0.7 + float(i) * 1.618),
			cos(t * 0.5 + float(i) * 2.236)
		) * drift;
		vec2 pt = fract(base + osc);
		vec2 delta = abs(uv - pt);
		vec2 wd = min(delta, 1.0 - delta);
		float dist = dot(wd, wd);
		if (dist < best_dist) {
			best_dist = dist;
			best_index = i;
		}
	}

	vec3 cs = vec3(seed_f + 100.0, float(best_index) * 13.37, 5.0);
	vec3 cell_color = mix(hash33(cs), user_color, 0.6);
	return vec4(cell_color, best_dist);
}

float centerMask(vec2 uv) {
	vec2 centered = abs(uv - 0.5);
	float dist = max(centered.x, centered.y);
	return clamp(dist * 2.0, 0.0, 1.0);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	ivec2 coords = ivec2(int(gl_FragCoord.x), int(gl_FragCoord.y));
	ivec2 dims = textureSize(inputTex, 0);

	vec4 base = texelFetch(inputTex, coords, 0);
	float blend_alpha = clamp(alpha, 0.0, 1.0);
	if (blend_alpha <= 0.0) {
		frag = base;
		return;
	}

	float seed_f = seed;
	float t = time * speed;
	vec3 user_color = color;

	// Voronoi at current position (for wormhole direction).
	vec4 base_vor = voronoiCell(uv, seed_f, t, user_color);

	// Wormhole distortion.
	float luma = luminance(base_vor.rgb);
	float angle = luma * LL_TAU + t * speed * 0.5;
	vec2 warp = vec2(cos(angle), sin(angle)) * 0.25;
	vec2 warped_uv = fract(uv + warp);

	// Voronoi at warped position.
	vec4 warp_vor = voronoiCell(warped_uv, seed_f, t, user_color);

	// Approximate bloom using distance falloff.
	float glow = exp(-warp_vor.w * 12.0);
	vec3 bloom_color = mix(warp_vor.rgb, warp_vor.rgb * 1.3, glow);

	// Mix wormhole result with bloom.
	vec3 leak = clamp(
		mix(sqrt(clamp(warp_vor.rgb, vec3(0.0), vec3(1.0))), bloom_color, 0.55),
		vec3(0.0), vec3(1.0)
	);

	// Screen blend: 1 - (1 - base) * (1 - leak).
	vec3 screened = vec3(1.0) - (vec3(1.0) - base.rgb) * (vec3(1.0) - leak);

	// Center mask: leak is stronger away from center.
	float mask = pow(centerMask(uv), 4.0);
	vec3 masked = mix(base.rgb, screened, mask);

	// Vaseline-style soft blur via neighbor texel fetches.
	vec3 soft_accum = masked * 4.0;
	float soft_w = 4.0;
	ivec2 max_coord = dims - ivec2(1);
	ivec2 nb0 = clamp(coords + ivec2(2, 0), ivec2(0), max_coord);
	ivec2 nb1 = clamp(coords + ivec2(-2, 0), ivec2(0), max_coord);
	ivec2 nb2 = clamp(coords + ivec2(0, 2), ivec2(0), max_coord);
	ivec2 nb3 = clamp(coords + ivec2(0, -2), ivec2(0), max_coord);
	soft_accum += texelFetch(inputTex, nb0, 0).rgb;
	soft_accum += texelFetch(inputTex, nb1, 0).rgb;
	soft_accum += texelFetch(inputTex, nb2, 0).rgb;
	soft_accum += texelFetch(inputTex, nb3, 0).rgb;
	soft_w += 4.0;
	vec3 vaseline = soft_accum / soft_w;

	// Final blend with alpha.
	vec3 final_color = mix(base.rgb, mix(masked, vaseline, blend_alpha), blend_alpha);
	vec3 clamped = clamp(final_color, vec3(0.0), vec3(1.0));
	frag = vec4(clamped, base.a);
}

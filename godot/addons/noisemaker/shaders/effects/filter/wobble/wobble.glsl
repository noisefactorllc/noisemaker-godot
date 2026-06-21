#version 450
// filter/wobble — ported PIXEL-IDENTICALLY from wgsl/wobble.wgsl. Offsets the whole
// frame's sample coords by a time/speed-driven PCG-noise jitter, with a wrap mode. A
// COORD-RESAMPLING warp. Single render pass (progName "wobble").
//
// No-layout effect (wobble.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define speed …`/`#define range …`/`#define wrap …`
// (uniform fields) plus the engine `#define time …`. Bare names; NO UBO / NO
// uniforms. Input texture bound at set 0, binding 1. No shared nm_core primitives are
// used (this effect inlines its OWN pcg/hash31/noise3d), so nm_core.glsl is NOT
// included.
//
// BASE UV: the WGSL samples at `in.uv` (the interpolated [0,1] vertex UV); the
// reference GLSL uses `v_texCoord`. Our pipeline does not pass a separate flipped
// vertex UV to filters; like every other ported filter we derive the base UV from
// gl_FragCoord (top-left, matches the global flip). The noise offset added is a
// frame-uniform jitter independent of the per-pixel UV origin.
//
// ⚠️ select→ternary (operands reversed): WGSL `select(a, b, cond)` == `cond ? b : a`.
// The hash31 seed uses `select(-p.c*2+1, p.c*2, p.c>=0)` → `p.c>=0 ? p.c*2 : -p.c*2+1`
// (this matches the reference GLSL form, reproduced verbatim). int param `wrap`
// arrives as a float component → `int(wrap)`. WGSL `>> 16u` etc. on uvec3 verbatim.
// f32(0xffffffffu)→float(0xffffffffu). TAU/seeds verbatim. No arithmetic changes.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float TAU = 6.28318530717959;
const vec3 X_NOISE_SEED = vec3(17.0, 29.0, 11.0);
const vec3 Y_NOISE_SEED = vec3(41.0, 23.0, 7.0);

// pcg — wobble's OWN PCG PRNG, inlined verbatim from WGSL.
uvec3 pcg(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v ^= v >> uvec3(16u);
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

// hash31 — verbatim. WGSL `select(-p.c*2+1, p.c*2, p.c>=0)` → `p.c>=0 ? … : …`.
float hash31(vec3 p) {
	uvec3 seed = uvec3(
		uint(p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0),
		uint(p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0),
		uint(p.z >= 0.0 ? p.z * 2.0 : -p.z * 2.0 + 1.0)
	);
	return float(pcg(seed).x) / float(0xffffffffu);
}

// noise3d — verbatim from WGSL (value noise with smoothstep fade).
float noise3d(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);

	float n000 = hash31(i);
	float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(i + vec3(1.0, 1.0, 1.0));

	float x0 = mix(n000, n100, f.x);
	float x1 = mix(n010, n110, f.x);
	float x2 = mix(n001, n101, f.x);
	float x3 = mix(n011, n111, f.x);

	float y0 = mix(x0, x1, f.y);
	float y1 = mix(x2, x3, f.y);

	return mix(y0, y1, f.z);
}

// simplexRandom — verbatim from WGSL (param `seed` is not a reserved name).
float simplexRandom(float t, float spd, vec3 seed) {
	float angle = t * TAU;
	float z = cos(angle) * spd + seed.x + spd * 0.317;
	float w = sin(angle) * spd + seed.y + spd * 0.519;
	float n = noise3d(vec3(z, w, seed.z + spd * 0.1));
	return clamp(n, 0.0, 1.0);
}

// applyWrap — verbatim; reads the injected `wrap` macro, narrowed with int().
vec2 applyWrap(vec2 uv) {
	int mode = int(wrap);
	if (mode == 0) {
		// mirror: abs(mod(uv + 1, 2) - 1)
		return abs(mod(uv + 1.0, 2.0) - 1.0);
	} else if (mode == 1) {
		return fract(uv);  // repeat
	}
	return clamp(uv, 0.0, 1.0);  // clamp
}

void main() {
	// WGSL: let spd = max(speed, 0.001); let r = max(range, 0.0);
	float spd = max(speed, 0.001);
	float r = max(range, 0.0);

	// Compute jitter offsets.
	float xRandom = simplexRandom(time + speed * 0.1, spd, X_NOISE_SEED);
	float yRandom = simplexRandom(time + speed * 0.1, spd, Y_NOISE_SEED);

	// Scale offset by range. WGSL: offsetScale = r * (0.01 + speed*0.02);
	float offsetScale = r * (0.01 + speed * 0.02);
	vec2 offset = (vec2(xRandom, yRandom) - 0.5) * offsetScale;

	// Apply offset to texture coordinate. Base UV from gl_FragCoord (see header).
	vec2 baseUV = gl_FragCoord.xy / vec2(textureSize(inputTex, 0));
	vec2 sampleCoord = baseUV + offset;
	sampleCoord = applyWrap(sampleCoord);

	frag = texture(inputTex, sampleCoord);
}

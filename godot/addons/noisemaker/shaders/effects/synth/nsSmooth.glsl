#version 450
// synth/navierStokes — program "nsSmooth" (smoothing / upsample). Ported from
// glsl/nsSmooth.glsl. Reads the low-res compute canvas (velocity+dye state) and applies the
// selected smoothing kernel during upsample to a SEPARATE full-res texture
// (global_ns_smoothed), so the compute canvas is never polluted by blended pixels. All 7
// sim-tag modes: 0 constant, 1 linear, 2 hermite, 3 catmullRom3x3, 4 catmullRom4x4,
// 5 bSpline3x3, 6 bSpline4x4. State surface bound NEAREST + clamp-to-edge -> texelFetch
// fetches exact texels (== WGSL textureLoad). No deltaTime / engine globals used.
//
// Layout effect: vec4 data[1] (effects/synth/navierStokes.json, uniformLayouts.nsSmooth):
//   resolution = data[0].xy, smoothing = int(data[0].z).
// Inputs (pass.inputs order): canvasTex = binding 1 (the compute canvas state).
// gl_FragCoord top-left, +0.5 — NO Y-flip.
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
layout(set = 0, binding = 1) uniform sampler2D canvasTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

vec4 fetchTex(ivec2 idx, ivec2 minIdx, ivec2 maxIdx) {
	return texelFetch(canvasTex, clamp(idx, minIdx, maxIdx), 0);
}

vec4 quad3v(vec4 p0, vec4 p1, vec4 p2, float t) {
	float t2 = t * t;
	return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
	       p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
	       p2 * 0.5 * t2;
}

vec4 bicubic4v(vec4 p0, vec4 p1, vec4 p2, vec4 p3, float t) {
	float t2 = t * t;
	float t3 = t2 * t;
	float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
	float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
	float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
	float b3 = t3 / 6.0;
	return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

vec4 catmull3v(vec4 p0, vec4 p1, vec4 p2, float t) {
	float t2 = t * t;
	float t3 = t2 * t;
	vec4 m = 0.5 * (p2 - p0);
	return (2.0*t3 - 3.0*t2 + 1.0) * p1 +
	       (t3 - 2.0*t2 + t) * m +
	       (-2.0*t3 + 3.0*t2) * p2 +
	       (t3 - t2) * m;
}

vec4 catmull4v(vec4 p0, vec4 p1, vec4 p2, vec4 p3, float t) {
	return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
}

void main() {
	vec2 res = data[0].xy;
	int smoothing = int(data[0].z);

	ivec2 texSize = textureSize(canvasTex, 0);
	ivec2 minIdx = ivec2(0);
	ivec2 maxIdx = texSize - ivec2(1);

	// Map our (full-res) pixel into the compute canvas's fractional texel grid.
	vec2 uv = gl_FragCoord.xy / res;
	vec2 texelPos = uv * vec2(texSize) - vec2(0.5);
	ivec2 baseI = ivec2(floor(texelPos));
	vec2 f = fract(texelPos);

	vec4 sampled;
	if (smoothing == 0) {
		ivec2 idx = clamp(ivec2(floor(texelPos + 0.5)), minIdx, maxIdx);
		sampled = texelFetch(canvasTex, idx, 0);
	} else if (smoothing == 2) {
		vec4 v00 = fetchTex(baseI,                       minIdx, maxIdx);
		vec4 v10 = fetchTex(baseI + ivec2(1, 0),         minIdx, maxIdx);
		vec4 v01 = fetchTex(baseI + ivec2(0, 1),         minIdx, maxIdx);
		vec4 v11 = fetchTex(baseI + ivec2(1, 1),         minIdx, maxIdx);
		vec2 w = smoothstep(vec2(0.0), vec2(1.0), f);
		vec4 v0 = mix(v00, v10, w.x);
		vec4 v1 = mix(v01, v11, w.x);
		sampled = mix(v0, v1, w.y);
	} else if (smoothing == 3) {
		vec4 p[9];
		for (int j = 0; j < 3; j++) {
			for (int i = 0; i < 3; i++) {
				p[j * 3 + i] = fetchTex(baseI + ivec2(i - 1, j - 1), minIdx, maxIdx);
			}
		}
		vec4 r0 = catmull3v(p[0], p[1], p[2], f.x);
		vec4 r1 = catmull3v(p[3], p[4], p[5], f.x);
		vec4 r2 = catmull3v(p[6], p[7], p[8], f.x);
		sampled = catmull3v(r0, r1, r2, f.y);
	} else if (smoothing == 4) {
		vec4 p[16];
		for (int j = 0; j < 4; j++) {
			for (int i = 0; i < 4; i++) {
				p[j * 4 + i] = fetchTex(baseI + ivec2(i - 1, j - 1), minIdx, maxIdx);
			}
		}
		vec4 r0 = catmull4v(p[0], p[1], p[2], p[3], f.x);
		vec4 r1 = catmull4v(p[4], p[5], p[6], p[7], f.x);
		vec4 r2 = catmull4v(p[8], p[9], p[10], p[11], f.x);
		vec4 r3 = catmull4v(p[12], p[13], p[14], p[15], f.x);
		sampled = catmull4v(r0, r1, r2, r3, f.y);
	} else if (smoothing == 5) {
		vec4 p[9];
		for (int j = 0; j < 3; j++) {
			for (int i = 0; i < 3; i++) {
				p[j * 3 + i] = fetchTex(baseI + ivec2(i - 1, j - 1), minIdx, maxIdx);
			}
		}
		vec4 r0 = quad3v(p[0], p[1], p[2], f.x);
		vec4 r1 = quad3v(p[3], p[4], p[5], f.x);
		vec4 r2 = quad3v(p[6], p[7], p[8], f.x);
		sampled = quad3v(r0, r1, r2, f.y);
	} else if (smoothing == 6) {
		vec4 p[16];
		for (int j = 0; j < 4; j++) {
			for (int i = 0; i < 4; i++) {
				p[j * 4 + i] = fetchTex(baseI + ivec2(i - 1, j - 1), minIdx, maxIdx);
			}
		}
		vec4 r0 = bicubic4v(p[0], p[1], p[2], p[3], f.x);
		vec4 r1 = bicubic4v(p[4], p[5], p[6], p[7], f.x);
		vec4 r2 = bicubic4v(p[8], p[9], p[10], p[11], f.x);
		vec4 r3 = bicubic4v(p[12], p[13], p[14], p[15], f.x);
		sampled = bicubic4v(r0, r1, r2, r3, f.y);
	} else {
		// linear (smoothing == 1)
		vec4 v00 = fetchTex(baseI,                       minIdx, maxIdx);
		vec4 v10 = fetchTex(baseI + ivec2(1, 0),         minIdx, maxIdx);
		vec4 v01 = fetchTex(baseI + ivec2(0, 1),         minIdx, maxIdx);
		vec4 v11 = fetchTex(baseI + ivec2(1, 1),         minIdx, maxIdx);
		vec4 v0 = mix(v00, v10, f.x);
		vec4 v1 = mix(v01, v11, f.x);
		sampled = mix(v0, v1, f.y);
	}

	frag = sampled;
}

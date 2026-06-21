#version 450
// filter/seamless — ported PIXEL-IDENTICALLY from wgsl/seamless.wgsl. Edge-blend
// cross-fade for seamless tiling: tiles the input `repeat` times, then bilinearly
// blends each tile toward its half-offset wraps near the tile edges (weighted by
// `blend` width and a `curve`). A COORD-RESAMPLING + multi-tap blend. Single render
// pass (progName "seamless").
//
// No-layout effect (seamless.json has no uniformLayout): the backend SYNTHESIZES
// the Params UBO and injects `#define blend …`/`#define repeat …`/`#define curve …`
// (+ engine globals). We use the bare names directly and declare NO UBO / NO
// uniforms. Input texture bound at set 0, binding 1.
//
// COORDINATE NOTE: WGSL `uv = position.xy / textureDimensions(inputTex)` — divide by
// the INPUT TEXTURE size. gl_FragCoord is top-left (matches WGSL); NO Y-flip.
// `curve` is an int param arriving as a float component of `vec4 data[]`; narrow
// with int(). `fract2(v) = v - floor(v)` is this effect's own helper (copied
// verbatim); the WGSL uses textureSampleLevel/textureSample (single mip), which map
// to texture() here (the backend sampler is single-mip). No arithmetic changes.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// edgeWeight — verbatim from WGSL `edgeWeight(t, width, c)`.
//   if (width <= 0.0) { return 0.0; }
//   let d = min(t, 1.0 - t);
//   let w = 1.0 - clamp(d / width, 0.0, 1.0);
//   if (c == 0) { return w; } else if (c == 2) { return w * w; }
//   return w * w * (3.0 - 2.0 * w);
float edgeWeight(float t, float width, int c) {
	if (width <= 0.0) { return 0.0; }
	float d = min(t, 1.0 - t);
	float w = 1.0 - clamp(d / width, 0.0, 1.0);
	if (c == 0) {
		return w;
	} else if (c == 2) {
		return w * w;
	}
	return w * w * (3.0 - 2.0 * w);
}

// fract2 — verbatim from WGSL: return v - floor(v);
vec2 fract2(vec2 v) {
	return v - floor(v);
}

void main() {
	int curveMode = int(curve);

	// WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
	vec2 texSize = vec2(textureSize(inputTex, 0));
	// WGSL: let uv = position.xy / texSize;
	vec2 uv = gl_FragCoord.xy / texSize;

	// WGSL: let st = fract2(uv * repeat);
	vec2 st = fract2(uv * repeat);

	// WGSL: let wx = edgeWeight(st.x, blend, curve); let wy = edgeWeight(st.y, blend, curve);
	float wx = edgeWeight(st.x, blend, curveMode);
	float wy = edgeWeight(st.y, blend, curveMode);

	// WGSL: the four samples (st, and the three half-offset wraps).
	vec4 c00 = texture(inputTex, st);
	vec4 c10 = texture(inputTex, fract2(st + vec2(0.5, 0.0)));
	vec4 c01 = texture(inputTex, fract2(st + vec2(0.0, 0.5)));
	vec4 c11 = texture(inputTex, fract2(st + vec2(0.5, 0.5)));

	// WGSL: bilinear blend using the edge weights.
	vec4 mx0 = mix(c00, c10, wx);
	vec4 mx1 = mix(c01, c11, wx);
	vec4 result = mix(mx0, mx1, wy);

	frag = vec4(result.rgb, 1.0);
}

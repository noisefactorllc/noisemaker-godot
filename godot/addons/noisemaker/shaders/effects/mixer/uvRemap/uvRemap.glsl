#version 450
// mixer/uvRemap — remap one input's UVs using another input's color channels.
// Single render pass, two inputs (pass.inputs order): inputTex = source A
// (binding 1), tex = source B / map (binding 2). No-layout effect: the backend
// injects the Params UBO + `#define mapSource …`/`channel …`/`scale …`/`offset …`/
// `wrap …` and the engine globals `resolution`/`fullResolution`/`tileOffset`,
// used here as bare names.
//
// Ported PIXEL-IDENTICALLY from the WebGL2 golden (the parity ground truth),
// shaders/effects/mixer/uvRemap/glsl/uvRemap.glsl — NOT the WGSL. The two
// DIVERGE: the WGSL picks mapSource==0 -> map=colorB / sampleFromB=0, but the
// golden INVERTS this (map=colorA / sampleFromB=1) and additionally tile-corrects
// the remapped UV via `(uv*fullResolution - tileOffset)/resolution` then `fract`
// (the WGSL omits that). The HLSL port (Shaders/Effects/mixer/UvRemap.hlsl)
// documents the same WGSL/GLSL inversion hazard. helpers (mirrorWrap/applyWrap)
// are this effect's own copies, inlined verbatim.
//
// Coord-resampling: `tex`'s channels become UV coordinates used to resample
// `inputTex`. Relies on the backend's NEAREST sampler (matching the reference's
// gl.NEAREST effect render targets) so resampled fetches land on the enclosing
// texel rather than a linear blend of neighbors.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float mirrorWrap(float t) {
	float m = mod(t, 2.0);
	return m > 1.0 ? 2.0 - m : m;
}

vec2 applyWrap(vec2 uv, int wrapMode) {
	if (wrapMode == 0) {
		return clamp(uv, 0.0, 1.0);
	} else if (wrapMode == 1) {
		return vec2(mirrorWrap(uv.x), mirrorWrap(uv.y));
	} else {
		return fract(uv);
	}
}

void main() {
	// WGSL/GLSL i32 uniforms (mapSource/channel/wrap) — capture as ints (the
	// backend injects them as float `data[].comp`; GLSL forbids implicit
	// float->int, so the applyWrap(int) call and the == compares need real ints).
	int mapSourceI = int(mapSource);
	int channelI = int(channel);
	int wrapI = int(wrap);

	vec2 localUV = gl_FragCoord.xy / resolution;
	vec4 colorA = texture(inputTex, localUV);
	vec4 colorB = texture(tex, localUV);

	vec4 mapColor = (mapSourceI == 0) ? colorA : colorB;
	int sampleFromB = (mapSourceI == 0) ? 1 : 0;

	vec2 rawUV;
	if (channelI == 0) {
		rawUV = mapColor.rg;
	} else if (channelI == 1) {
		rawUV = vec2(mapColor.r, mapColor.b);
	} else {
		rawUV = vec2(mapColor.g, mapColor.b);
	}

	float s = scale / 100.0;
	vec2 remappedUV = rawUV * s + offset;
	remappedUV = applyWrap(remappedUV, wrapI);

	vec2 sampleUV = (remappedUV * fullResolution - tileOffset) / resolution;
	sampleUV = fract(sampleUV);

	vec4 result;
	if (sampleFromB == 1) {
		result = texture(tex, sampleUV);
	} else {
		result = texture(inputTex, sampleUV);
	}

	frag = result;
}

#version 450
// synth/navierStokes — program "nsAdvect" (semi-Lagrangian advection). Ported from
// glsl/nsAdvect.glsl. Canonical bilinear backtrace sample (hand-rolled from texelFetch on
// integer texels — matches the WGSL textureLoad path exactly), then per-channel decay.
// State rgba16f: velocity R,G; dye B. NO deltaTime engine global — dt = speed*0.0001.
//
// Layout effect: vec4 data[2] (effects/synth/navierStokes.json, uniformLayouts.nsAdvect):
//   resolution = data[0].xy, speed = data[0].w, dyeDecay = data[1].x,
//   velocityDecay = data[1].y.
// Inputs (pass.inputs order): bufTex = binding 1 (read state).
// gl_FragCoord top-left, +0.5 — NO Y-flip.
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[2]; };
layout(set = 0, binding = 1) uniform sampler2D bufTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

vec4 fetchTex(ivec2 idx, ivec2 minIdx, ivec2 maxIdx) {
	return texelFetch(bufTex, clamp(idx, minIdx, maxIdx), 0);
}

vec4 sampleBilinear(vec2 uv, ivec2 texSize) {
	ivec2 minIdx = ivec2(0);
	ivec2 maxIdx = texSize - ivec2(1);
	vec2 texelPos = uv * vec2(texSize) - vec2(0.5);
	ivec2 baseI = ivec2(floor(texelPos));
	vec2 f = fract(texelPos);

	vec4 v00 = fetchTex(baseI,                       minIdx, maxIdx);
	vec4 v10 = fetchTex(baseI + ivec2(1, 0),         minIdx, maxIdx);
	vec4 v01 = fetchTex(baseI + ivec2(0, 1),         minIdx, maxIdx);
	vec4 v11 = fetchTex(baseI + ivec2(1, 1),         minIdx, maxIdx);
	vec4 v0 = mix(v00, v10, f.x);
	vec4 v1 = mix(v01, v11, f.x);
	return mix(v0, v1, f.y);
}

void main() {
	float speed = data[0].w;
	float dyeDecay = data[1].x;
	float velocityDecay = data[1].y;

	ivec2 texSize = textureSize(bufTex, 0);
	vec2 fragCoord = gl_FragCoord.xy;
	vec2 uv = fragCoord / vec2(texSize);

	vec4 here = texelFetch(bufTex, clamp(ivec2(fragCoord), ivec2(0), texSize - ivec2(1)), 0);
	vec2 u = here.rg;

	float dt = clamp(speed, 0.0, 200.0) * 0.0001;
	vec2 backUv = clamp(uv - u * dt, vec2(0.0), vec2(1.0));

	vec4 advected = sampleBilinear(backUv, texSize);
	vec2 newVel = advected.rg;
	float newDye = advected.b;

	float vDecay = pow(clamp(velocityDecay, 0.0, 100.0) * 0.01, dt * 60.0);
	float dDecay = pow(clamp(dyeDecay, 0.0, 100.0) * 0.01, dt * 60.0);

	newVel *= vDecay;
	newDye *= dDecay;

	frag = vec4(newVel, newDye, 1.0);
}

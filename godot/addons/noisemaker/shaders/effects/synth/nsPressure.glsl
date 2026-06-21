#version 450
// synth/navierStokes — program "nsPressure" (Jacobi iteration). Ported from
// glsl/nsPressure.glsl (golden source). One step of the Jacobi solver for laplacian(p) =
// div(u). Pressure in R, divergence in G (preserved across iterations). The runtime
// ping-pongs the pressure state texture and repeats this pass `iterations` times per frame.
// State surfaces are bound NEAREST + clamp-to-edge, so texture(bufTex, uv +/- texel)
// fetches the exact neighbour texel (== the WGSL textureLoad path). No deltaTime / engine
// globals used.
//
// Layout effect: vec4 data[1] (effects/synth/navierStokes.json, uniformLayouts.nsPressure):
//   resolution = data[0].xy.
// Inputs (pass.inputs order): bufTex = binding 1 (read pressure state).
// gl_FragCoord top-left, +0.5 — NO Y-flip.
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
layout(set = 0, binding = 1) uniform sampler2D bufTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 texSize = textureSize(bufTex, 0);
	vec2 fragCoord = gl_FragCoord.xy;
	vec2 texel = 1.0 / vec2(texSize);
	vec2 uv = fragCoord / vec2(texSize);

	float pR = texture(bufTex, uv + vec2(texel.x, 0.0)).r;
	float pL = texture(bufTex, uv - vec2(texel.x, 0.0)).r;
	float pT = texture(bufTex, uv + vec2(0.0, texel.y)).r;
	float pB = texture(bufTex, uv - vec2(0.0, texel.y)).r;

	float div = texture(bufTex, uv).g;

	float p = (pR + pL + pT + pB - div) * 0.25;

	frag = vec4(p, div, 0.0, 1.0);
}

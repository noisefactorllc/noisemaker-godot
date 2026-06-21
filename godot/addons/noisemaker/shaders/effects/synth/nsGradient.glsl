#version 450
// synth/navierStokes — program "nsGradient" (gradient subtraction / projection). Ported from
// glsl/nsGradient.glsl (golden source). Subtracts grad(p) from velocity so the result is
// divergence-free (Helmholtz-Hodge). Velocity stored unencoded in R,G; dye in B passed
// through untouched. State surfaces are bound NEAREST + clamp-to-edge, so the texture()
// neighbour lookups fetch exact texels (== the WGSL textureLoad path). No deltaTime /
// engine globals used.
//
// Layout effect: vec4 data[1] (effects/synth/navierStokes.json, uniformLayouts.nsGradient):
//   resolution = data[0].xy.
// Inputs (pass.inputs order): velTex = binding 1 (velocity state), pressureTex = binding 2.
// gl_FragCoord top-left, +0.5 — NO Y-flip.
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
layout(set = 0, binding = 1) uniform sampler2D velTex;
layout(set = 0, binding = 2) uniform sampler2D pressureTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 texSize = textureSize(velTex, 0);
	vec2 fragCoord = gl_FragCoord.xy;
	vec2 texel = 1.0 / vec2(texSize);
	vec2 uv = fragCoord / vec2(texSize);

	float pR = texture(pressureTex, uv + vec2(texel.x, 0.0)).r;
	float pL = texture(pressureTex, uv - vec2(texel.x, 0.0)).r;
	float pT = texture(pressureTex, uv + vec2(0.0, texel.y)).r;
	float pB = texture(pressureTex, uv - vec2(0.0, texel.y)).r;

	vec2 grad = 0.5 * vec2(pR - pL, pT - pB);

	vec4 here = texture(velTex, uv);
	vec2 u = here.rg - grad;

	frag = vec4(u, here.b, 1.0);
}

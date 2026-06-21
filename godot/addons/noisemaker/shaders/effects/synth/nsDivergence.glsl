#version 450
// synth/navierStokes — program "nsDivergence". Ported from glsl/nsDivergence.glsl (golden
// source). Centered finite difference of velocity into the G channel of pressure state,
// zeroing R so the Jacobi iterations start from p = 0 each frame. Free-slip boundaries
// mirror the normal velocity component. State surfaces are bound NEAREST + clamp-to-edge,
// so texture(velTex, uv +/- texel) fetches the exact neighbour texel (== the WGSL
// textureLoad path). No deltaTime / engine globals used.
//
// Layout effect: vec4 data[1] (effects/synth/navierStokes.json, uniformLayouts.nsDivergence):
//   resolution = data[0].xy.
// Inputs (pass.inputs order): velTex = binding 1 (read velocity state).
// gl_FragCoord top-left, +0.5 — NO Y-flip.
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
layout(set = 0, binding = 1) uniform sampler2D velTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 texSize = textureSize(velTex, 0);
	vec2 fragCoord = gl_FragCoord.xy;
	vec2 texel = 1.0 / vec2(texSize);
	vec2 uv = fragCoord / vec2(texSize);

	vec2 uR = texture(velTex, uv + vec2(texel.x, 0.0)).rg;
	vec2 uL = texture(velTex, uv - vec2(texel.x, 0.0)).rg;
	vec2 uT = texture(velTex, uv + vec2(0.0, texel.y)).rg;
	vec2 uB = texture(velTex, uv - vec2(0.0, texel.y)).rg;

	// Free-slip at boundaries: mirror normal component so velocity can't drive flow through walls.
	if (fragCoord.x < 1.0) { uL.x = -uR.x; }
	if (fragCoord.x > float(texSize.x) - 1.0) { uR.x = -uL.x; }
	if (fragCoord.y < 1.0) { uB.y = -uT.y; }
	if (fragCoord.y > float(texSize.y) - 1.0) { uT.y = -uB.y; }

	float div = 0.5 * ((uR.x - uL.x) + (uT.y - uB.y));

	frag = vec4(0.0, div, 0.0, 1.0);
}

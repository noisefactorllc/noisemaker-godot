#version 450
// filter/celShading program "celShadingBlend" — ported from
// wgsl/celShadingBlend.wgsl. Composites cel-shaded color with edge outlines, then
// mixes with the original. Pass 3 of 3.
//
// No-layout effect: backend injects the Params UBO + `#define edgeColor …`/
// `mixAmount …` and engine globals. THREE inputs (pass.inputs order):
//   inputTex = original scene  (binding 1)
//   colorTex = celShadingColorTex (binding 2)
//   edgeTex  = celShadingEdgeTex  (binding 3)
//
// PORTING NOTES:
//  * Ported from WGSL (top-left, canonical) — NO per-effect Y flip.
//  * uv = gl_FragCoord.xy / textureSize(inputTex, 0) — fragCoord divided by the
//    inputTex size; all three textures sampled at this same uv (matching the WGSL).
//  * Arithmetic reproduced literally; full f32.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D colorTex;
layout(set = 0, binding = 3) uniform sampler2D edgeTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	vec4 origColor = texture(inputTex, uv);
	vec4 celColor = texture(colorTex, uv);
	float edgeStrength = texture(edgeTex, uv).r;

	// Apply edge color where edges are detected
	vec3 finalColor = mix(celColor.rgb, edgeColor, edgeStrength);

	// Mix with original based on mix amount
	finalColor = mix(origColor.rgb, finalColor, mixAmount);

	frag = vec4(finalColor, origColor.a);
}

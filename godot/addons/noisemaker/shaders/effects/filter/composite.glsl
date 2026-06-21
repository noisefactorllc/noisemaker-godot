#version 450
// filter/bloom program "composite" — ported from wgsl/composite.wgsl.
// Adds tinted bloom to the original HDR scene. All operations in linear color space.
// No-layout effect: backend injects Params UBO + `#define intensity …`/`tint …` and
// engine globals. Two inputs (pass.inputs order): inputTex = original scene
// (binding 1), bloomTex = gathered bloom (binding 2).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D bloomTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	// Get original scene color (HDR)
	vec4 sceneColor = texture(inputTex, uv);

	// Get bloom color
	vec3 bloom = texture(bloomTex, uv).rgb;

	// Apply tint
	bloom *= tint;

	// Additive blend: finalHDR = sceneColor + intensity * bloom
	vec3 finalRgb = sceneColor.rgb + intensity * bloom;

	frag = vec4(finalRgb, sceneColor.a);
}

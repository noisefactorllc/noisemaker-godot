#version 450
// filter/colorReplace — ported from wgsl/colorReplace.wgsl. Color replacement with
// alpha output: matches input pixels by euclidean RGB distance to targetColor, then
// independently remaps RGB toward replaceColor and rescales alpha.
// No-layout effect: the backend injects the Params UBO + `#define targetColor …`/
// `#define replaceColor …` (both vec3 → data[slot].xyz), `#define sensitivity …`,
// `#define smoothing …`, `#define colorMix …`, `#define replaceAlpha …`,
// `#define keepAlpha …` (synthesized layout) and engine globals, so we use the bare
// reference names directly. Input texture bound at set 0, binding 1.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 size = max(textureSize(inputTex, 0), ivec2(1, 1));
	vec2 st = gl_FragCoord.xy / vec2(size);
	vec4 src = textureLod(inputTex, st, 0.0);

	float dist = length(src.rgb - targetColor) / 1.7320508;

	float halfBand = smoothing * 0.5;
	float edge0 = max(sensitivity - halfBand, 0.0);
	float edge1 = sensitivity + halfBand;
	float match_ = 1.0 - smoothstep(edge0, edge1, dist);

	vec3 outRgb = mix(src.rgb, replaceColor, vec3(match_ * colorMix));
	float outA = src.a * mix(keepAlpha, replaceAlpha, match_);

	frag = vec4(outRgb, outA);
}

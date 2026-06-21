#version 450
// filter/threshold — ported from wgsl/thresh.wgsl. Binary threshold with
// adjustable edge softness.
// No-layout effect: the backend injects the Params UBO + `#define level …`/
// `#define sharpness …` (synthesized layout) and engine globals, so we use the
// bare reference names directly. Input texture bound at set 0, binding 1.
// gl_FragCoord is top-left, +0.5 — no Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 st = gl_FragCoord.xy / vec2(textureSize(inputTex, 0));
	vec4 c = texture(inputTex, st);
	float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	float e = smoothstep(level - sharpness, level + sharpness, l);
	frag = vec4(vec3(e), 1.0);
}

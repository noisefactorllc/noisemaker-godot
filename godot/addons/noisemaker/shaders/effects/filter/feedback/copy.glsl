#version 450
// filter/feedback (program "copy") — ported from wgsl/copy.wgsl.
// Passthrough/blit that snapshots this frame's output back into the feedback buffer
// `_selfTex` for the next settle frame. Divides by the input texture's OWN size
// (textureSize), NOT `resolution`. No-layout effect: backend injects the Params UBO
// + engine globals. Single input bound at set 0, binding 1 (pass.inputs order):
// inputTex (= the prior pass's outputTex).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / dims;
	frag = texture(inputTex, uv);
}

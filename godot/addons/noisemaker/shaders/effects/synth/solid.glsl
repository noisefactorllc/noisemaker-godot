#version 450
// synth/solid — ported from wgsl/solid.wgsl. Constant color, premultiplied alpha.
// No-layout effect: the backend injects the Params UBO + `#define color …`/`#define
// alpha …` (synthesized layout), so we use the bare reference names directly.
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	frag = vec4(color * alpha, alpha);
}

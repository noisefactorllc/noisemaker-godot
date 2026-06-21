#version 450
// filter/smoothstep — ported from wgsl/smoothstep.wgsl. Smoothstep threshold
// effect: smooth Hermite transition between edge0 and edge1.
// No-layout effect: the backend injects the Params UBO + `#define edge0 …`/
// `#define edge1 …` (synthesized layout) and engine globals, so we use the
// bare reference names directly. Input texture bound at set 0, binding 1.
// (The WGSL `let edge0/edge1` locals are dropped — they only aliased the
// uniforms, which are already the injected bare names; keeping them would
// collide with the `#define`s. `smoothstep` stays the GLSL builtin.)
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 color = texture(inputTex, uv);

	color = vec4(smoothstep(vec3(edge0), vec3(edge1), color.rgb), color.a);

	frag = color;
}

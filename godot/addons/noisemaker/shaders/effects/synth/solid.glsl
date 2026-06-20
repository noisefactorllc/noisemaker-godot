#version 450
// synth/solid — ported from wgsl/solid.wgsl. Constant color, premultiplied alpha.
// Individual-uniform effect (no reference uniformLayout): Phase-0 packer lays the
// pass uniforms out in declaration order from slot 0, so data[0] = (color.rgb, alpha).
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec3 color = data[0].xyz;
	float alpha = data[0].w;
	frag = vec4(color * alpha, alpha);
}

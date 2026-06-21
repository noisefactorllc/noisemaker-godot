#version 450
// mixer/channelCombine (program "channelCombine") — ported from wgsl/channelCombine.wgsl.
// Builds an RGB image from the LUMINANCE of three separate input textures, one per output
// channel, each scaled by its level. No-layout effect: the backend injects the Params UBO +
// `#define rLevel …`/`gLevel …`/`bLevel …` and the engine `resolution`. Inputs bind at set 0
// in pass.inputs order: rTex = binding 1, gTex = binding 2, bTex = binding 3. gl_FragCoord is
// top-left/+0.5 like the WGSL @position — NO Y-flip.
layout(set = 0, binding = 1) uniform sampler2D rTex;
layout(set = 0, binding = 2) uniform sampler2D gTex;
layout(set = 0, binding = 3) uniform sampler2D bTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float luminance(vec4 c) {
	return dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
	vec2 st = gl_FragCoord.xy / resolution;

	float r = luminance(texture(rTex, st)) * rLevel / 100.0;
	float g = luminance(texture(gTex, st)) * gLevel / 100.0;
	float b = luminance(texture(bTex, st)) * bLevel / 100.0;

	frag = vec4(r, g, b, 1.0);
}

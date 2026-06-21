#version 450
// filter/channel — ported from wgsl/channel.wgsl. Extracts a single RGBA channel
// (r=0, g=1, b=2, a=3) as grayscale, then applies fract(v * scale + offset).
// No-layout effect: the backend injects the Params UBO + `#define channel …`/
// `#define scale …`/`#define offset …` (synthesized layout) and engine globals,
// so we use the bare reference names directly. Input texture bound at set 0,
// binding 1. `channel` is i32 in the WGSL but arrives as a float define here, so
// it is cast with int(...).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	// WGSL: let st = position.xy / vec2<f32>(textureDimensions(inputTex, 0));
	vec2 st = gl_FragCoord.xy / vec2(textureSize(inputTex, 0));
	// WGSL: let c = textureSample(inputTex, samp, st);
	vec4 c = texture(inputTex, st);

	float v;
	if (int(channel) == 0) {
		v = c.r;
	} else if (int(channel) == 1) {
		v = c.g;
	} else if (int(channel) == 2) {
		v = c.b;
	} else {
		v = c.a;
	}

	// WGSL: v = fract(v * scale + offset);
	v = fract(v * scale + offset);

	// WGSL: return vec4<f32>(vec3<f32>(v), 1.0);
	frag = vec4(vec3(v), 1.0);
}

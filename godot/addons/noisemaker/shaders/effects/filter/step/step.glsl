#version 450
// filter/step — ported from wgsl/step.wgsl. Step threshold effect: creates a
// hard edge at the threshold value (with optional antialiasing).
// No-layout effect: the backend injects the Params UBO + `#define threshold …`/
// `#define antialias …` (synthesized layout) and engine globals, so we use the
// bare reference names directly. Input texture bound at set 0, binding 1.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 color = texture(inputTex, uv);

	if (int(antialias) != 0) {
		vec3 fw = fwidth(color.rgb);
		color = vec4(
			smoothstep(threshold - fw * 0.5, threshold + fw * 0.5, color.rgb),
			color.a
		);
	} else {
		color = vec4(step(vec3(threshold), color.rgb), color.a);
	}

	frag = color;
}

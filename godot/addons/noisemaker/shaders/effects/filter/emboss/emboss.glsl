#version 450
// filter/emboss — ported from wgsl/emboss.wgsl. 3x3 emboss convolution producing
// a raised relief appearance.
// No-layout effect: backend injects Params UBO + `amount` and engine globals.
// Input texture bound at set 0, binding 1 (pass.inputs order).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec2 texelSize = 1.0 / texSize;

	vec4 origColor = texture(inputTex, uv);

	// Emboss kernel
	float kernel[9] = float[9](-2.0, -1.0, 0.0, -1.0, 1.0, 1.0, 0.0, 1.0, 2.0);

	vec2 offsets[9] = vec2[9](
		vec2(-texelSize.x, -texelSize.y),
		vec2(0.0, -texelSize.y),
		vec2(texelSize.x, -texelSize.y),
		vec2(-texelSize.x, 0.0),
		vec2(0.0, 0.0),
		vec2(texelSize.x, 0.0),
		vec2(-texelSize.x, texelSize.y),
		vec2(0.0, texelSize.y),
		vec2(texelSize.x, texelSize.y)
	);

	vec3 conv = vec3(0.0);

	for (int i = 0; i < 9; i = i + 1) {
		vec3 sampleColor = texture(inputTex, uv + offsets[i] * amount).rgb;
		conv = conv + sampleColor * kernel[i];
	}

	frag = vec4(clamp(conv, vec3(0.0), vec3(1.0)), origColor.a);
}

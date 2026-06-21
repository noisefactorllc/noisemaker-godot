#version 450
// filter/bloom program "brightPass" — ported from wgsl/brightPass.wgsl.
// Bloom bright-pass extraction: isolates highlight energy using a luma threshold
// + soft knee. All math in linear color space.
// No-layout effect: backend injects Params UBO + `#define threshold …`/`softKnee …`
// and engine globals. Input texture bound at set 0, binding 1 (pass.inputs order).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 color = texture(inputTex, uv);

	// Compute luminance (Rec. 709)
	float luma = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));

	// Soft knee thresholding
	float knee = softKnee;
	float threshLow = threshold - knee;
	float threshHigh = threshold + knee;

	float bloomFactor;
	if (luma <= threshLow) {
		bloomFactor = 0.0;
	} else if (luma >= threshHigh) {
		bloomFactor = 1.0;
	} else {
		// Smoothstep for the soft knee region
		float t = (luma - threshLow) / (threshHigh - threshLow);
		bloomFactor = t * t * (3.0 - 2.0 * t);
	}

	// Multiply original HDR color by bloom factor
	vec3 brightColor = color.rgb * bloomFactor;

	frag = vec4(brightColor, color.a);
}

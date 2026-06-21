#version 450
// filter/sine — ported from wgsl/sine.wgsl. Sine wave distortion.
// RGB mode: apply sine to R, G, B independently. Non-RGB (mono) mode:
// convert to luminance, apply sine, output grayscale.
// No-layout effect: the backend injects the Params UBO + `#define amount …`/
// `#define colorMode …` (synthesized layout) and engine globals, so we use the
// bare reference names directly. Input texture bound at set 0, binding 1.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float normalized_sine(float value) {
	return (sin(value) + 1.0) * 0.5;
}

void main() {
	bool use_rgb = int(colorMode) > 0;

	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 color = texture(inputTex, uv);

	if (use_rgb) {
		color.r = normalized_sine(color.r * amount);
		color.g = normalized_sine(color.g * amount);
		color.b = normalized_sine(color.b * amount);
	} else {
		float lum = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b;
		float result = normalized_sine(lum * amount);
		color = vec4(result, result, result, color.a);
	}

	frag = color;
}

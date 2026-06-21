#version 450
// filter/outline program "outlineValueMap" — ported from wgsl/outlineValueMap.wgsl.
// Pass 1 of 3: convert input to a perceptual-luminance value map for edge
// detection. Near-grey texels fall back to clamp(r); chromatic texels use the
// Oklab L component (sRGB->linear->LMS->cube-root->L).
// No-layout effect (globals: shape/sobelMetric, thickness, invert): backend
// injects the Params UBO + engine globals. Input texture (inputTex) bound at
// set 0, binding 1 (pass.inputs order). Backend sampler is NEAREST + clamp, so
// texture(inputTex, gl_FragCoord.xy/texSize) reads the exact texel at the
// fragment center — matching the WGSL textureSample(texCoord) pass-through.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float srgbToLinear(float value) {
	if (value <= 0.04045) {
		return value / 12.92;
	}
	return pow((value + 0.055) / 1.055, 2.4);
}

vec3 srgbToLinear3(vec3 value) {
	return vec3(srgbToLinear(value.r), srgbToLinear(value.g), srgbToLinear(value.b));
}

float cubeRoot(float value) {
	if (value < 0.0) {
		return -pow(-value, 1.0 / 3.0);
	}
	return pow(value, 1.0 / 3.0);
}

float oklabLComponent(vec3 rgb) {
	vec3 linearRgb = srgbToLinear3(clamp(rgb, vec3(0.0), vec3(1.0)));
	float l = 0.4121656120 * linearRgb.r + 0.5362752080 * linearRgb.g + 0.0514575653 * linearRgb.b;
	float m = 0.2118591070 * linearRgb.r + 0.6807189584 * linearRgb.g + 0.1074065790 * linearRgb.b;
	float s = 0.0883097947 * linearRgb.r + 0.2818474174 * linearRgb.g + 0.6302613616 * linearRgb.b;
	float lC = cubeRoot(max(l, 1e-9));
	float mC = cubeRoot(max(m, 1e-9));
	float sC = cubeRoot(max(s, 1e-9));
	return clamp(0.2104542553 * lC + 0.7936177850 * mC - 0.0040720468 * sC, 0.0, 1.0);
}

float valueMapComponent(vec4 texel) {
	float spread = max(abs(texel.r - texel.g), max(abs(texel.r - texel.b), abs(texel.g - texel.b)));
	if (spread < 1e-5) {
		return clamp(texel.r, 0.0, 1.0);
	}
	return oklabLComponent(texel.rgb);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 texel = texture(inputTex, uv);
	float value = valueMapComponent(texel);
	frag = vec4(value, value, value, texel.a);
}

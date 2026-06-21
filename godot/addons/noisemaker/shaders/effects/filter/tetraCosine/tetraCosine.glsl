#version 450
// filter/tetraCosine — ported from wgsl/tetraCosine.wgsl, cross-checked against the
// reference glsl (golden source). Applies an Inigo-Quilez cosine palette to the input
// based on luminance; supports RGB/HSV/OkLab/OKLCH color modes. Layout effect:
// packed uniformLayout vec4 data[5] (effects/filter/tetraCosine.json). Top-left origin
// (Godot/Vulkan), no Y-flip. Samples the texture once (no coord resampling).

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[5]; };
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// uniformLayout aliases
#define offsetR data[0].x
#define offsetG data[0].y
#define offsetB data[0].z
#define colorModeF data[0].w
#define ampR data[1].x
#define ampG data[1].y
#define ampB data[1].z
#define repeatVal data[1].w
#define freqRF data[2].x
#define freqGF data[2].y
#define freqBF data[2].z
#define offsetVal data[2].w
#define phaseR data[3].x
#define phaseG data[3].y
#define phaseB data[3].z
#define alpha data[3].w
#define rotationF data[4].x
#define time data[4].y

const float TAU = 6.283185307179586;

// ============================================================================
// Color Space Conversions
// ============================================================================

// HSV to RGB
vec3 hsv2rgb(vec3 hsv) {
	float h = hsv.x;
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float hp = h * 6.0;
	float x = c * (1.0 - abs(mod(hp, 2.0) - 1.0));
	float m = v - c;

	vec3 rgb;
	if (hp < 1.0) {
		rgb = vec3(c, x, 0.0);
	} else if (hp < 2.0) {
		rgb = vec3(x, c, 0.0);
	} else if (hp < 3.0) {
		rgb = vec3(0.0, c, x);
	} else if (hp < 4.0) {
		rgb = vec3(0.0, x, c);
	} else if (hp < 5.0) {
		rgb = vec3(x, 0.0, c);
	} else {
		rgb = vec3(c, 0.0, x);
	}

	return rgb + vec3(m);
}

// OkLab to linear RGB
vec3 oklab2linear(vec3 lab) {
	float L = lab.x;
	float a = lab.y;
	float b = lab.z;

	float l_ = L + 0.3963377774 * a + 0.2158037573 * b;
	float m_ = L - 0.1055613458 * a - 0.0638541728 * b;
	float s_ = L - 0.0894841775 * a - 1.2914855480 * b;

	float l = l_ * l_ * l_;
	float m = m_ * m_ * m_;
	float s = s_ * s_ * s_;

	return vec3(
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
	);
}

// Linear to sRGB gamma
vec3 linear2srgb(vec3 lin) {
	vec3 low = lin * 12.92;
	vec3 high = 1.055 * pow(max(lin, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
	return mix(high, low, step(lin, vec3(0.0031308)));
}

// OkLab to sRGB (cosine output is 0-1, a/b need remapping from 0-1 to -0.4..0.4)
vec3 oklab2rgb(vec3 lab) {
	float L = lab.x;
	float a = (lab.y - 0.5) * 0.8;  // 0-1 -> -0.4 to 0.4
	float b = (lab.z - 0.5) * 0.8;  // 0-1 -> -0.4 to 0.4

	vec3 linear_rgb = oklab2linear(vec3(L, a, b));
	return clamp(linear2srgb(linear_rgb), 0.0, 1.0);
}

// OKLCH to sRGB (cosine output is L 0-1, C 0-1 representing 0-0.4, H 0-1)
vec3 oklch2rgb(vec3 lch) {
	float L = lch.x;
	float C = lch.y * 0.4;  // 0-1 -> 0 to 0.4
	float H = lch.z * TAU;  // 0-1 -> 0 to 2pi

	float a = C * cos(H);
	float b = C * sin(H);

	vec3 linear_rgb = oklab2linear(vec3(L, a, b));
	return clamp(linear2srgb(linear_rgb), 0.0, 1.0);
}

// ============================================================================
// Cosine Palette
// ============================================================================

vec3 cosinePalette(float t, vec3 palOffset, vec3 amp, vec3 freq, vec3 phase) {
	return clamp(palOffset + amp * cos(TAU * (freq * t + phase)), 0.0, 1.0);
}

void main() {
	int colorMode = int(colorModeF);
	int rotation = int(rotationF);

	// Calculate UV from gl_FragCoord (top-left, no flip)
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	// Get input color
	vec4 inputColor = texture(inputTex, uv);

	// Calculate luminance as the t value
	float lum = dot(inputColor.rgb, vec3(0.299, 0.587, 0.114));

	// Apply mapping: repeat, offset, and rotation (animation)
	float t = lum * repeatVal + offsetVal;

	if (rotation == -1) {
		t += time;
	} else if (rotation == 1) {
		t -= time;
	}

	t = fract(t);

	// Build palette parameters from uniforms (freq is conceptually int)
	vec3 palOffset = vec3(offsetR, offsetG, offsetB);
	vec3 amp = vec3(ampR, ampG, ampB);
	vec3 freq = vec3(float(int(freqRF)), float(int(freqGF)), float(int(freqBF)));
	vec3 phase = vec3(phaseR, phaseG, phaseB);

	// Evaluate cosine palette
	vec3 paletteColor = cosinePalette(t, palOffset, amp, freq, phase);

	// Convert from color mode to RGB
	vec3 finalColor;
	if (colorMode == 1) {
		finalColor = hsv2rgb(paletteColor);
	} else if (colorMode == 2) {
		finalColor = oklab2rgb(paletteColor);
	} else if (colorMode == 3) {
		finalColor = oklch2rgb(paletteColor);
	} else {
		finalColor = paletteColor;
	}

	// Blend with original based on alpha
	vec3 blendedColor = mix(inputColor.rgb, finalColor, alpha);

	frag = vec4(blendedColor, inputColor.a);
}

#version 450
// filter/colorspace — ported from wgsl/colorspace.wgsl. Treats input RGB channels
// as HSV, OKLab, or OKLCH values and converts to RGB.
// No-layout effect: backend injects the Params UBO + `#define mode …` (synthesized
// layout) and engine globals, so we use the bare reference name `mode` directly.
// Input texture bound at set 0, binding 1 (pass.inputs order).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// WGSL: const TAU: f32 = 6.28318530718;
const float TAU = 6.28318530718;

// Floored modulo (matches GLSL mod behavior for negative values) — effect's own helper.
float floorMod(float x, float y) {
	return x - y * floor(x / y);
}

// HSV to RGB — effect's own helper, ported verbatim.
vec3 hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;
	float c = v * s;
	float x = c * (1.0 - abs(floorMod(h * 6.0, 2.0) - 1.0));
	float m = v - c;
	vec3 rgb;
	if (h < 1.0/6.0) { rgb = vec3(c, x, 0.0); }
	else if (h < 2.0/6.0) { rgb = vec3(x, c, 0.0); }
	else if (h < 3.0/6.0) { rgb = vec3(0.0, c, x); }
	else if (h < 4.0/6.0) { rgb = vec3(0.0, x, c); }
	else if (h < 5.0/6.0) { rgb = vec3(x, 0.0, c); }
	else { rgb = vec3(c, 0.0, x); }
	return rgb + m;
}

// OKLab to linear sRGB matrices (column-major; vec3 args are columns, verbatim from WGSL).
const mat3 fwdA = mat3(
	vec3(1.0, 1.0, 1.0),
	vec3(0.3963377774, -0.1055613458, -0.0894841775),
	vec3(0.2158037573, -0.0638541728, -1.2914855480)
);

const mat3 fwdB = mat3(
	vec3(4.0767245293, -1.2681437731, -0.0041119885),
	vec3(-3.3072168827, 2.6093323231, -0.7034763098),
	vec3(0.2307590544, -0.3411344290, 1.7068625689)
);

vec3 linear_srgb_from_oklab(vec3 c) {
	vec3 lms = fwdA * c;
	return fwdB * (lms * lms * lms);
}

// `linear` is a reserved word in GLSL/MSL — renamed param to `lin`.
vec3 linearToSrgb(vec3 lin) {
	vec3 srgb;
	for (int i = 0; i < 3; i = i + 1) {
		if (lin[i] <= 0.0031308) {
			srgb[i] = lin[i] * 12.92;
		} else {
			srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055;
		}
	}
	return srgb;
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 color = texture(inputTex, uv);

	if (int(mode) == 0) {
		// HSV
		color = vec4(hsv2rgb(color.rgb), color.a);
	} else if (int(mode) == 1) {
		// OKLab
		// Remap RGB to OKLab range and convert
		// magic values from py-noisemaker
		vec3 lab = color.rgb;
		lab.g = lab.g * -0.509 + 0.276;
		lab.b = lab.b * -0.509 + 0.198;

		vec3 rgb = linear_srgb_from_oklab(lab);
		rgb = linearToSrgb(rgb);
		color = vec4(rgb, color.a);
	} else {
		// OKLCH - interpret RGB as L, C, H
		float L = color.r;
		float C = color.g * 0.4; // Scale chroma to reasonable range
		float H = color.b * TAU; // Hue as angle

		// Convert LCH to Lab
		float a = C * cos(H);
		float b = C * sin(H);

		vec3 rgb = linear_srgb_from_oklab(vec3(L, a, b));
		rgb = linearToSrgb(rgb);
		color = vec4(rgb, color.a);
	}

	frag = color;
}

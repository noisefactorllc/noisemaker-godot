#version 450
// filter/adjust — ported from wgsl/adjust.wgsl. Combined color adjustment:
// colorspace reinterpretation (RGB / HSV / OKLab / OKLCH) + hue/saturation +
// brightness/contrast, in one render pass.
// No-layout effect: the backend injects the Params UBO + `#define mode …`/
// `#define rotation …`/`#define hueRange …`/`#define saturation …`/
// `#define brightness …`/`#define contrast …` (synthesized layout) and engine
// globals, so we use the bare reference names directly. `mode` is an int param
// delivered as a float #define -> cast int(mode) at use sites.
// Input texture bound at set 0, binding 1 (pass.inputs order).
// Helpers ported VERBATIM and INLINE per PORTING-GUIDE (not the nm_core variants).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// WGSL: const TAU: f32 = 6.28318530718;
const float TAU = 6.28318530718;

// mapVal(value, inMin, inMax, outMin, outMax) — effect's own helper, verbatim.
float mapVal(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// floorMod(x, y) = x - y * floor(x / y) — effect's own helper, verbatim.
float floorMod(float x, float y) {
	return x - y * floor(x / y);
}

// --- Colorspace functions (verbatim from WGSL) ---

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

vec3 rgb2hsv(vec3 rgb) {
	float r = rgb.r; float g = rgb.g; float b = rgb.b;
	float maxC = max(r, max(g, b));
	float minC = min(r, min(g, b));
	float delta = maxC - minC;

	float h = 0.0;
	if (delta != 0.0) {
		if (maxC == r) {
			h = floorMod((g - b) / delta, 6.0) / 6.0;
		} else if (maxC == g) {
			h = ((b - r) / delta + 2.0) / 6.0;
		} else {
			h = ((r - g) / delta + 4.0) / 6.0;
		}
	}
	float s = 0.0;
	if (maxC != 0.0) { s = delta / maxC; }
	return vec3(h, s, maxC);
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

	// --- Colorspace reinterpretation ---
	if (int(mode) == 1) {
		// HSV
		color = vec4(hsv2rgb(color.rgb), color.a);
	} else if (int(mode) == 2) {
		// OKLab
		vec3 lab = color.rgb;
		lab.g = lab.g * -0.509 + 0.276;
		lab.b = lab.b * -0.509 + 0.198;
		vec3 rgb = linear_srgb_from_oklab(lab);
		rgb = linearToSrgb(rgb);
		color = vec4(rgb, color.a);
	} else if (int(mode) == 3) {
		// OKLCH - interpret RGB as L, C, H
		float L = color.r;
		float C = color.g * 0.4;
		float H = color.b * TAU;
		float a = C * cos(H);
		float b = C * sin(H);
		vec3 rgb = linear_srgb_from_oklab(vec3(L, a, b));
		rgb = linearToSrgb(rgb);
		color = vec4(rgb, color.a);
	}

	// --- Hue / Saturation ---
	vec3 hsv = rgb2hsv(color.rgb);
	hsv.x = fract(hsv.x * mapVal(hueRange, 0.0, 200.0, 0.0, 2.0) + (rotation / 360.0));
	hsv.y = hsv.y * saturation;
	color = vec4(hsv2rgb(hsv), color.a);

	// --- Brightness / Contrast ---
	color = vec4(color.rgb * brightness, color.a);
	float contrastFactor = contrast * 2.0;
	color = vec4((color.rgb - 0.5) * contrastFactor + 0.5, color.a);

	frag = color;
}

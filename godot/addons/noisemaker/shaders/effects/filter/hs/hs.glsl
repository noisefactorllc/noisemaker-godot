#version 450
// filter/hs — ported from wgsl/hs.wgsl. Hue rotation and saturation adjustment
// (deprecated; use filter/adjust instead).
// No-layout effect: the backend injects the Params UBO + `#define rotation …`/
// `#define hueRange …`/`#define saturation …` (synthesized layout) and engine
// globals, so we use the bare reference names directly. Input texture bound at
// set 0, binding 1.
//
// rgb2hsv / hsv2rgb / floorMod / mapVal are THIS effect's own per-effect helpers,
// ported VERBATIM inline (golden rule 2) — do not substitute a generic version.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// WGSL: fn floorMod(x: f32, y: f32) -> f32 { return x - y * floor(x / y); }
float hs_floorMod(float x, float y) {
	return x - y * floor(x / y);
}

// WGSL: fn mapVal(value, inMin, inMax, outMin, outMax) -> f32 {
//           return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin); }
float hs_mapVal(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

vec3 hs_rgb2hsv(vec3 rgb) {
	float r = rgb.r; float g = rgb.g; float b = rgb.b;
	float maxC = max(r, max(g, b));
	float minC = min(r, min(g, b));
	float delta = maxC - minC;

	float h = 0.0;
	if (delta != 0.0) {
		if (maxC == r) {
			h = hs_floorMod((g - b) / delta, 6.0) / 6.0;
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

vec3 hs_hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;
	float c = v * s;
	float x = c * (1.0 - abs(hs_floorMod(h * 6.0, 2.0) - 1.0));
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

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 color = texture(inputTex, uv);

	// Convert to HSV
	vec3 hsv = hs_rgb2hsv(color.rgb);

	// Apply hue rotation and range scaling
	hsv.x = fract(hsv.x * hs_mapVal(hueRange, 0.0, 200.0, 0.0, 2.0) + (rotation / 360.0));

	// Apply saturation
	hsv.y = hsv.y * saturation;

	// Convert back to RGB
	color = vec4(hs_hsv2rgb(hsv), color.a);

	frag = color;
}

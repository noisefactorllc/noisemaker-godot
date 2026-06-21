#version 450
// filter/prismaticAberration — ported PIXEL-IDENTICALLY from
// wgsl/prismaticAberration.wgsl. Position-dependent RGB channel split (no zoom),
// edge extraction, then hue-boosted prismatic recombination with a desaturated
// passthrough. Single render pass (progName "prismaticAberration").
//
// No-layout effect (prismaticAberration.json has no uniformLayout): the backend
// SYNTHESIZES the Params UBO and injects `#define <name> data[slot].comp` for the
// engine globals and every param uniform. Param uniform FIELDS (not JSON keys):
// aberrationAmt, modulate, hueRotation, hueRange, saturation, passthru. We use the
// bare names directly. `modulate` is a bool param arriving as float → tested
// `!= 0.0`. Engine `time` used (bare).
//
// ⚠️ RESERVED-NAME COLLISION: the WGSL's local `aspectRatio` collides with the
// injected `#define aspectRatio data[0].w` engine macro → renamed to `ar`. The
// WGSL computes it from fullResolution; for the (single-frame, non-tiling) parity
// path fullResolution==textureSize, so we compute ar = texSize.x/texSize.y.
//
// COORDINATE NOTE: ported from WGSL (top-left, no Y-flip): uv = gl_FragCoord.xy /
// texSize. The WGSL samples `(coord * fullResolution - tileOffset) / texSize`; with
// tileOffset=0 and fullResolution==texSize that is just `coord`, so we sample uv
// directly (we do not reproduce the tiling remap). WGSL float `%` (floor modulo) →
// GLSL `mod`. Helpers (map/hsv2rgb/rgb2hsv/saturate/floorMod) inlined verbatim from
// WGSL. No arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

#define PA_PI 3.14159265359
#define PA_TAU 6.28318530718

// Floored modulo (matches GLSL mod behavior for negative values).
float floorMod(float x, float y) {
	return x - y * floor(x / y);
}

float mapVal(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

vec3 hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float x = c * (1.0 - abs(mod(h * 6.0, 2.0) - 1.0));
	float m = v - c;

	vec3 rgb;

	if (h < 1.0 / 6.0) {
		rgb = vec3(c, x, 0.0);
	} else if (h < 2.0 / 6.0) {
		rgb = vec3(x, c, 0.0);
	} else if (h < 3.0 / 6.0) {
		rgb = vec3(0.0, c, x);
	} else if (h < 4.0 / 6.0) {
		rgb = vec3(0.0, x, c);
	} else if (h < 5.0 / 6.0) {
		rgb = vec3(x, 0.0, c);
	} else {
		rgb = vec3(c, 0.0, x);
	}

	return rgb + vec3(m, m, m);
}

vec3 rgb2hsv(vec3 rgb) {
	float r = rgb.r;
	float g = rgb.g;
	float b = rgb.b;

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
	if (h < 0.0) { h = h + 1.0; }

	float s = 0.0;
	if (maxC != 0.0) {
		s = delta / maxC;
	}
	float v = maxC;

	return vec3(h, s, v);
}

vec3 saturateColor(vec3 color) {
	float sat = mapVal(saturation, -100.0, 100.0, -1.0, 1.0);
	float avg = (color.r + color.g + color.b) / 3.0;
	return color - (avg - color) * sat;
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	float ar = texSize.x / texSize.y;
	vec2 uv = gl_FragCoord.xy / texSize;

	vec4 color = vec4(0.0, 0.0, 0.0, 1.0);

	vec2 diff = vec2(0.5 * ar, 0.5) - vec2(uv.x * ar, uv.y);
	float centerDist = length(diff);

	// No distortion/zoom.
	vec2 lensedCoords = uv;

	float aberrationOffset = mapVal(aberrationAmt, 0.0, 100.0, 0.0, 0.05) * centerDist * PA_PI * 0.5;

	float redOffset = mix(clamp(lensedCoords.x + aberrationOffset, 0.0, 1.0), lensedCoords.x, lensedCoords.x);
	vec4 red = texture(inputTex, vec2(redOffset, lensedCoords.y));

	vec4 green = texture(inputTex, lensedCoords);

	float blueOffset = mix(lensedCoords.x, clamp(lensedCoords.x - aberrationOffset, 0.0, 1.0), lensedCoords.x);
	vec4 blue = texture(inputTex, vec2(blueOffset, lensedCoords.y));

	// from aberration
	vec3 hsv = vec3(1.0);

	float t = 0.0;
	if (modulate != 0.0) {
		t = time;
	}

	// prismatic - get edges
	color = vec4(vec3(length(vec4(red.r, green.g, blue.b, color.a) - green)) * green.rgb, green.a);

	// boost hue range of edges
	hsv = rgb2hsv(color.rgb);
	hsv = vec3(fract(((hsv.x + 0.125 + (1.0 - (hueRotation / 360.0))) * (2.0 + hueRange * 0.05)) + t), 1.0, hsv.z);

	// desaturate original
	vec3 greenMod = saturateColor(green.rgb) * mapVal(passthru, 0.0, 100.0, 0.0, 2.0);

	// recombine (add)
	color = vec4(min(greenMod + hsv2rgb(hsv), vec3(1.0)), color.a);

	frag = color;
}

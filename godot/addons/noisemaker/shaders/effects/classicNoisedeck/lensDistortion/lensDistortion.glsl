#version 450
// classicNoisedeck/lensDistortion — barrel/pincushion lensing with chromatic/prismatic
// aberration, tint, hue shaping and vignette. Ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/classicNoisedeck/lensDistortion/wgsl/lensDistortion.wgsl
// (cross-checked against the reference GLSL).
//
// Single render pass (program "lensDistortion"). Input-taker: reads inputTex (no-layout
// effect, lensDistortion.json declares no uniformLayout). The backend SYNTHESIZES the
// Params UBO and injects `#define <name> data[slot].comp` for the 8 engine globals plus
// every param's `uniform` field: shape, distortion, aspectLens, loopScale, speed, mode,
// aberration, blendMode, modulate, tint, alpha, hueRotation, hueRange, saturation,
// passthru, vignetteAmt. We use the bare names directly. Engine `time`, `resolution`
// read (bare). `tint` is a `color` param → injected as a vec3 macro (matches the WGSL's
// `u.tint.rgb` usage). Input texture set 0, binding 1.
//
// ⚠️ RESERVED-NAME COLLISIONS: main()'s local `aspectRatio` (= resolution.x/.y) and the
// same local inside _distance() collide with the engine #define → renamed to `ar` (pure
// symbol rename; this shader never reads the engine aspectRatio).
//
// FAITHFUL-PORT NOTE: _distance()'s `(sin(t * TAU) + 1.0 * 0.5)` is reproduced literally
// (precedence makes it `sin(t*TAU) + 0.5`) — a deliberate verbatim copy, not simplified.
//
// WGSL `%` → GLSL `mod()`. WGSL vecNf → GLSL vecN. gl_FragCoord top-left (Godot/Vulkan,
// matches WGSL) — NO per-effect Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float LD_PI = 3.14159265359;
const float LD_TAU = 6.28318530718;

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
			h = mod((g - b) / delta, 6.0) / 6.0;
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

float _distance(vec2 diff, vec2 uv) {
	// `aspectRatio` is an injected engine #define → rename the local.
	float ar = resolution.x / resolution.y;
	float uvx = uv.x * ar;
	float dist = 1.0;

	if (shape == 0) {
		// Euclidean
		dist = length(diff);
	} else if (shape == 1) {
		// Manhattan
		dist = abs(uvx - 0.5 * ar) + abs(uv.y - 0.5);
	} else if (shape == 2) {
		// hexagon
		dist = max(max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y), max(abs(diff.x) - diff.y * 0.5, 1.0 * diff.y));
	} else if (shape == 3) {
		// octagon
		dist = max((abs(uvx - 0.5 * ar) + abs(uv.y - 0.5)) / sqrt(2.0), max(abs(uvx - 0.5 * ar), abs(uv.y - 0.5)));
	} else if (shape == 4) {
		// Chebychev
		dist = max(abs(uvx - 0.5 * ar), abs(uv.y - 0.5));
	} else if (shape == 6) {
		// Triangle
		dist = max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y);
	} else if (shape == 10) {
		// Cosine
		dist = 1.0 - length(vec2((cos(diff.x * LD_TAU) + 1.0) * 0.5, (cos(diff.y * LD_TAU) + 1.0) * 0.5));
	}

	float lf = mapVal(loopScale, 1.0, 100.0, 6.0, 1.0);

	float t = 1.0;
	if (speed < 0.0) {
		t = dist * lf + time;
	} else {
		t = dist * lf - time;
	}
	return mix(dist,
	           (sin(t * LD_TAU) + 1.0 * 0.5) * abs(speed) * 0.005,
	           abs(speed) * 0.01);
}

void main() {
	float ar = resolution.x / resolution.y;
	vec2 uv = gl_FragCoord.xy / resolution;

	vec4 color = vec4(0.0, 0.0, 0.0, 1.0);

	vec2 diff = vec2(0.5) - uv;
	if (aspectLens != 0.0) {
		diff = vec2(0.5 * ar, 0.5) - vec2(uv.x * ar, uv.y);
	}
	float centerDist = _distance(diff, uv);

	float distort = 0.0;
	float zoom = 1.0;
	if (distortion < 0.0) {
		distort = mapVal(distortion, -100.0, 0.0, -2.0, 0.0);
		zoom = mapVal(distortion, -100.0, 0.0, 0.04, 0.0);
	} else {
		distort = mapVal(distortion, 0.0, 100.0, 0.0, 2.0);
		zoom = mapVal(distortion, 0.0, 100.0, 0.0, -1.0);
	}

	// aberration and lensing
	vec2 lensedCoords = fract((uv - diff * zoom) - diff * centerDist * centerDist * distort);

	float aberrationOffset = mapVal(aberration, 0.0, 100.0, 0.0, 0.05) * centerDist * LD_PI * 0.5;

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

	if (mode == 0) {
		// chromatic
		color = vec4(red.r, green.g, blue.b, color.a) - green;
		color = vec4(color.rgb, green.a);

		// tweak hue of edges
		hsv = rgb2hsv(color.rgb);
		hsv = vec3(fract(hsv.x + (1.0 - (hueRotation / 360.0)) + hsv.x * hueRange * 0.01 + t), 1.0, hsv.z);
	} else {
		// prismatic
		// get edges
		color = vec4(vec3(length(vec4(red.r, green.g, blue.b, color.a) - green)) * green.rgb, green.a);

		// boost hue range of edges
		hsv = rgb2hsv(color.rgb);
		hsv = vec3(fract(((hsv.x + 0.125 + (1.0 - (hueRotation / 360.0))) * (2.0 + hueRange * 0.05)) + t), 1.0, hsv.z);
	}

	// desaturate original
	vec3 greenMod = saturateColor(green.rgb) * mapVal(passthru, 0.0, 100.0, 0.0, 2.0);

	// recombine
	if (blendMode == 0) {
		// add
		color = vec4(min(greenMod + hsv2rgb(hsv), vec3(1.0)), color.a);
	} else if (blendMode == 1) {
		// alpha
		color = vec4(min(max(greenMod - vec3(hsv.z), vec3(0.0)) + hsv2rgb(hsv), vec3(1.0)), color.a);
	}
	// end aberration

	// apply tint (this was the "reflect" mode from blendo)
	vec3 tintResult;
	if (all(equal(color.rgb, vec3(1.0)))) {
		tintResult = color.rgb;
	} else {
		tintResult = min(tint * tint / (vec3(1.0) - color.rgb), vec3(1.0));
	}
	color = vec4(mix(color.rgb, tintResult, alpha * 0.01), max(color.a, alpha * 0.01));

	// vignette
	if (vignetteAmt < 0.0) {
		float vigFactor = 1.0 - pow(length(vec2(0.5) - uv) * 1.125, 2.0);
		color = vec4(
			mix(color.rgb * vigFactor, color.rgb, mapVal(vignetteAmt, -100.0, 0.0, 0.0, 1.0)),
			max(color.a, length(vec2(0.5) - uv) * mapVal(vignetteAmt, -100.0, 0.0, 1.0, 0.0))
		);
	} else {
		float vigFactor = 1.0 - pow(length(vec2(0.5) - uv) * 1.125, 2.0);
		color = vec4(
			mix(color.rgb, vec3(1.0) - (vec3(1.0) - color.rgb * vigFactor), mapVal(vignetteAmt, 0.0, 100.0, 0.0, 1.0)),
			max(color.a, length(vec2(0.5) - uv) * mapVal(vignetteAmt, -100.0, 0.0, 1.0, 0.0))
		);
	}

	frag = color;
}

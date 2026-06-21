#version 450
// classicNoisedeck/refract — noise-based UV refraction of the input feed. Ported
// PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/refract/wgsl/refract.wgsl
// (cross-checked against the reference GLSL; the reference GLSL adds tileOffset/
// fullResolution tiling remaps + a tiling displacement clamp the WGSL lacks — NOT
// reproduced here, per the porting guide. WGSL is the source of truth.)
//
// Single render pass (program "refract"). Input-taker: reads inputTex (no-layout effect,
// refract.json declares no uniformLayout). The backend SYNTHESIZES the Params UBO and
// injects `#define <name> data[slot].comp` for the 8 engine globals plus every param's
// `uniform` field: blendMode, mixAmt, mode, amount, direction, wrap. We use the bare
// names directly. No engine globals are read here (uv comes from gl_FragCoord/textureSize).
// Input texture at set 0, binding 1.
//
// No reserved-name collisions: the params (mode/amount/direction/blendMode/mixAmt/wrap)
// appear only as bare uniforms; no helper takes a parameter with one of those names.
//
// COORDINATE NOTE (from WGSL): dims = textureSize(inputTex, 0); uv = gl_FragCoord.xy/dims.
// gl_FragCoord is top-left (Godot/Vulkan, matches WGSL) — NO per-effect Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float REFRACT_PI = 3.14159265359;
const float REFRACT_TAU = 6.28318530718;

float map_range(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float desaturate(vec3 color) {
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

vec3 convolve_kernel(vec2 uv, float kernel[9], bool divide) {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 steps = 1.0 / dims;
	vec2 offsets[9];
	offsets[0] = vec2(-steps.x, -steps.y);
	offsets[1] = vec2(0.0, -steps.y);
	offsets[2] = vec2(steps.x, -steps.y);
	offsets[3] = vec2(-steps.x, 0.0);
	offsets[4] = vec2(0.0, 0.0);
	offsets[5] = vec2(steps.x, 0.0);
	offsets[6] = vec2(-steps.x, steps.y);
	offsets[7] = vec2(0.0, steps.y);
	offsets[8] = vec2(steps.x, steps.y);

	float kernelWeight = 0.0;
	vec3 conv = vec3(0.0);
	float scale = floor(map_range(amount, 0.0, 100.0, 0.0, 20.0));

	for (int i = 0; i < 9; i = i + 1) {
		vec3 color = texture(inputTex, uv + offsets[i] * scale).rgb;
		conv = conv + color * kernel[i];
		kernelWeight = kernelWeight + kernel[i];
	}

	if (divide && kernelWeight != 0.0) {
		conv = conv / kernelWeight;
	}

	return clamp(conv, vec3(0.0), vec3(1.0));
}

vec3 derivX(vec2 uv, bool divide) {
	float kernel[9];
	kernel[0] = 0.0; kernel[1] = 0.0; kernel[2] = 0.0;
	kernel[3] = 0.0; kernel[4] = 1.0; kernel[5] = -1.0;
	kernel[6] = 0.0; kernel[7] = 0.0; kernel[8] = 0.0;
	return convolve_kernel(uv, kernel, divide);
}

vec3 derivY(vec2 uv, bool divide) {
	float kernel[9];
	kernel[0] = 0.0; kernel[1] = 0.0; kernel[2] = 0.0;
	kernel[3] = 0.0; kernel[4] = 1.0; kernel[5] = 0.0;
	kernel[6] = 0.0; kernel[7] = -1.0; kernel[8] = 0.0;
	return convolve_kernel(uv, kernel, divide);
}

float blendOverlay(float a, float b) {
	if (a < 0.5) {
		return 2.0 * a * b;
	}
	return 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
}

float blendSoftLight(float base, float blend) {
	if (blend < 0.5) {
		return 2.0 * base * blend + base * base * (1.0 - 2.0 * blend);
	}
	return sqrt(base) * (2.0 * blend - 1.0) + 2.0 * base * (1.0 - blend);
}

bool vec4_eq(vec4 a, vec4 b) {
	return all(equal(a, b));
}

vec3 blend_colors(vec4 color1, vec4 color2) {
	vec4 color;
	vec4 middle;
	float amt = map_range(mixAmt, 0.0, 100.0, 0.0, 1.0);

	if (blendMode == 0) {
		// add
		middle = min(color1 + color2, vec4(1.0));
	} else if (blendMode == 2) {
		// color burn
		if (vec4_eq(color2, vec4(0.0))) {
			middle = color2;
		} else {
			middle = max((1.0 - ((1.0 - color1) / color2)), vec4(0.0));
		}
	} else if (blendMode == 3) {
		// color dodge
		if (vec4_eq(color2, vec4(1.0))) {
			middle = color2;
		} else {
			middle = min(color1 / (1.0 - color2), vec4(1.0));
		}
	} else if (blendMode == 4) {
		// darken
		middle = min(color1, color2);
	} else if (blendMode == 5) {
		// difference
		middle = abs(color1 - color2);
	} else if (blendMode == 6) {
		// exclusion
		middle = color1 + color2 - 2.0 * color1 * color2;
	} else if (blendMode == 7) {
		// glow
		if (vec4_eq(color2, vec4(1.0))) {
			middle = color2;
		} else {
			middle = min(color1 * color1 / (1.0 - color2), vec4(1.0));
		}
	} else if (blendMode == 8) {
		// hard light
		middle = vec4(
			blendOverlay(color2.r, color1.r),
			blendOverlay(color2.g, color1.g),
			blendOverlay(color2.b, color1.b),
			mix(color1.a, color2.a, 0.5)
		);
	} else if (blendMode == 9) {
		// lighten
		middle = max(color1, color2);
	} else if (blendMode == 10) {
		// mix
		middle = mix(color1, color2, 0.5);
	} else if (blendMode == 11) {
		// multiply
		middle = color1 * color2;
	} else if (blendMode == 12) {
		// negation
		middle = vec4(1.0) - abs(vec4(1.0) - color1 - color2);
	} else if (blendMode == 13) {
		// overlay
		middle = vec4(
			blendOverlay(color1.r, color2.r),
			blendOverlay(color1.g, color2.g),
			blendOverlay(color1.b, color2.b),
			mix(color1.a, color2.a, 0.5)
		);
	} else if (blendMode == 14) {
		// phoenix
		middle = min(color1, color2) - max(color1, color2) + vec4(1.0);
	} else if (blendMode == 15) {
		// reflect
		if (vec4_eq(color1, vec4(1.0))) {
			middle = color1;
		} else {
			middle = min(color2 * color2 / (1.0 - color1), vec4(1.0));
		}
	} else if (blendMode == 16) {
		// screen
		middle = 1.0 - ((1.0 - color1) * (1.0 - color2));
	} else if (blendMode == 17) {
		// soft light
		middle = vec4(
			blendSoftLight(color1.r, color2.r),
			blendSoftLight(color1.g, color2.g),
			blendSoftLight(color1.b, color2.b),
			mix(color1.a, color2.a, 0.5)
		);
	} else {
		// subtract (blendMode == 18)
		middle = max(color1 + color2 - 1.0, vec4(0.0));
	}

	if (amt == 0.5) {
		color = middle;
	} else if (amt < 0.5) {
		amt = map_range(amt, 0.0, 0.5, 0.0, 1.0);
		color = mix(color1, middle, amt);
	} else {
		amt = map_range(amt, 0.5, 1.0, 0.0, 1.0);
		color = mix(middle, color2, amt);
	}

	return color.rgb;
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / dims;

	vec4 color = vec4(0.0);
	vec4 inputColor = texture(inputTex, uv);
	float brightness = desaturate(inputColor.rgb) + direction / 360.0;

	if (mode == 0) {
		uv.x = uv.x + cos(brightness * REFRACT_TAU) * amount * 0.01;
		uv.y = uv.y + sin(brightness * REFRACT_TAU) * amount * 0.01;
	} else if (mode == 1) {
		uv.y = uv.y + desaturate(derivX(uv, false)) * amount * 0.01;
		uv.x = uv.x + desaturate(derivY(uv, false)) * amount * 0.01;
	}

	if (wrap == 0) {
		// mirror (default) - no change
	} else if (wrap == 1) {
		// repeat
		uv = fract(uv);
	} else if (wrap == 2) {
		// clamp
		uv = clamp(uv, vec2(0.0), vec2(1.0));
	}

	color = texture(inputTex, uv);
	color = vec4(blend_colors(inputColor, color), color.a);

	frag = color;
}

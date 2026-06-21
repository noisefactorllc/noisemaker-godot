#version 450
// filter/dither — ported PIXEL-IDENTICALLY from wgsl/dither.wgsl. Ordered dithering
// with classic patterns (Bayer 2x2/4x4/8x8, dot, line, crosshatch, noise) and retro
// color palettes, plus a per-channel quantization mode driven by `levels`.
//
// No-layout effect (dither.json has no uniformLayout): the backend injects the Params
// UBO + `#define ditherType …`/`matrixScale …`/… (synthesized layout, every param a
// float `data[slot].comp`) and engine globals (incl. `time`). We use the bare
// reference names and narrow the int-semantic params at the call site (int(...)),
// matching the WGSL Uniforms types: matrixScale/threshold/mixAmount are f32 there.
// Input texture bound at set 0, binding 1 (pass.inputs order). No Y-flip (top-left UV).
#include "include/nm_core.glsl"
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Dither type constants (WGSL const)
const int DITHER_BAYER_2X2 = 0;
const int DITHER_BAYER_4X4 = 1;
const int DITHER_BAYER_8X8 = 2;
const int DITHER_DOT = 3;
const int DITHER_LINE = 4;
const int DITHER_CROSSHATCH = 5;
const int DITHER_NOISE = 6;

// Palette constants (WGSL const)
const int PALETTE_INPUT = 0;
const int PALETTE_MONOCHROME = 1;
const int PALETTE_DOT_MATRIX_GREEN = 2;
const int PALETTE_AMBER = 3;
const int PALETTE_PICO8 = 4;
const int PALETTE_C64 = 5;
const int PALETTE_CGA = 6;
const int PALETTE_ZX_SPECTRUM = 7;
const int PALETTE_APPLE_II = 8;
const int PALETTE_EGA = 9;

// Bayer 2x2 matrix values — VERBATIM from dither.wgsl. idx = (y&1)*2 + (x&1).
float getBayer2x2(int x, int y) {
	float bayer[4] = float[4](
		0.0/4.0, 2.0/4.0,
		3.0/4.0, 1.0/4.0
	);
	int idx = (y & 1) * 2 + (x & 1);
	return bayer[idx];
}

// Bayer 4x4 matrix values — VERBATIM from dither.wgsl. idx = (y&3)*4 + (x&3).
float getBayer4x4(int x, int y) {
	float bayer[16] = float[16](
		 0.0/16.0,  8.0/16.0,  2.0/16.0, 10.0/16.0,
		12.0/16.0,  4.0/16.0, 14.0/16.0,  6.0/16.0,
		 3.0/16.0, 11.0/16.0,  1.0/16.0,  9.0/16.0,
		15.0/16.0,  7.0/16.0, 13.0/16.0,  5.0/16.0
	);
	int idx = (y & 3) * 4 + (x & 3);
	return bayer[idx];
}

// 8x8 Bayer matrix — VERBATIM from dither.wgsl. xm = x&7, ym = y&7, idx = ym*8 + xm.
float getBayer8x8(int x, int y) {
	int xm = x & 7;
	int ym = y & 7;

	// Standard 8x8 ordered dither matrix
	float bayer8[64] = float[64](
		 0.0/64.0, 32.0/64.0,  8.0/64.0, 40.0/64.0,  2.0/64.0, 34.0/64.0, 10.0/64.0, 42.0/64.0,
		48.0/64.0, 16.0/64.0, 56.0/64.0, 24.0/64.0, 50.0/64.0, 18.0/64.0, 58.0/64.0, 26.0/64.0,
		12.0/64.0, 44.0/64.0,  4.0/64.0, 36.0/64.0, 14.0/64.0, 46.0/64.0,  6.0/64.0, 38.0/64.0,
		60.0/64.0, 28.0/64.0, 52.0/64.0, 20.0/64.0, 62.0/64.0, 30.0/64.0, 54.0/64.0, 22.0/64.0,
		 3.0/64.0, 35.0/64.0, 11.0/64.0, 43.0/64.0,  1.0/64.0, 33.0/64.0,  9.0/64.0, 41.0/64.0,
		51.0/64.0, 19.0/64.0, 59.0/64.0, 27.0/64.0, 49.0/64.0, 17.0/64.0, 57.0/64.0, 25.0/64.0,
		15.0/64.0, 47.0/64.0,  7.0/64.0, 39.0/64.0, 13.0/64.0, 45.0/64.0,  5.0/64.0, 37.0/64.0,
		63.0/64.0, 31.0/64.0, 55.0/64.0, 23.0/64.0, 61.0/64.0, 29.0/64.0, 53.0/64.0, 21.0/64.0
	);

	return bayer8[ym * 8 + xm];
}

// Hash function for noise dithering — VERBATIM from dither.wgsl:
//   pcg(vec3(u32(select(-p.x*2+1, p.x*2, p.x>=0)), u32(select(...p.y...)), 0)).x
//     / f32(0xffffffffu)
// This sign-fold + pcg + /4294967295.0 is exactly nm_core random(p)
// (= prng(vec3(p, 0.0)).x), the one allowed shared primitive. Use it.
float hash(vec2 p) {
	return random(p);
}

// Dot pattern dithering — VERBATIM from dither.wgsl.
float dotPattern(vec2 uv, float scale) {
	vec2 p = uv * scale;
	float d = length(fract(p) - 0.5);
	return smoothstep(0.5, 0.0, d);
}

// Line pattern dithering — VERBATIM from dither.wgsl.
float linePattern(vec2 uv, float scale) {
	float p = uv.y * scale;
	return abs(fract(p) - 0.5) * 2.0;
}

// Crosshatch pattern — VERBATIM from dither.wgsl.
float crosshatchPattern(vec2 uv, float scale) {
	vec2 p = uv * scale;
	float line1 = abs(fract(p.x + p.y) - 0.5) * 2.0;
	float line2 = abs(fract(p.x - p.y) - 0.5) * 2.0;
	return min(line1, line2);
}

// Get dither threshold based on type and position — VERBATIM from dither.wgsl.
// scaledCoord = floor(pixelCoord/scale); pattern scales use 1.0/(8.0*scale);
// noise uses hash(scaledCoord + time*0.001).
// Param names ditherType/time/levels collide with backend-injected `#define`s, so
// helper parameters are suffixed `Arg` (matching the HLSL port). Bare names are used
// only at the call sites in main().
float getDitherThreshold(vec2 pixelCoord, int ditherTypeArg, float scale, float timeArg) {
	// Scale the pixel coordinate - larger scale = bigger pattern cells
	vec2 scaledCoord = floor(pixelCoord / scale);
	int x = int(scaledCoord.x);
	int y = int(scaledCoord.y);

	if (ditherTypeArg == DITHER_BAYER_2X2) {
		return getBayer2x2(x, y);
	} else if (ditherTypeArg == DITHER_BAYER_4X4) {
		return getBayer4x4(x, y);
	} else if (ditherTypeArg == DITHER_BAYER_8X8) {
		return getBayer8x8(x, y);
	} else if (ditherTypeArg == DITHER_DOT) {
		// Dot pattern with 8-pixel base, scaled (larger scale = bigger dots)
		return dotPattern(pixelCoord, 1.0 / (8.0 * scale));
	} else if (ditherTypeArg == DITHER_LINE) {
		// Line pattern with 8-pixel base
		return linePattern(pixelCoord, 1.0 / (8.0 * scale));
	} else if (ditherTypeArg == DITHER_CROSSHATCH) {
		// Crosshatch pattern with 8-pixel base
		return crosshatchPattern(pixelCoord, 1.0 / (8.0 * scale));
	} else if (ditherTypeArg == DITHER_NOISE) {
		// Noise pattern: scale determines block size
		return hash(scaledCoord + timeArg * 0.001);
	}

	return 0.5;
}

// Quantize color to specified levels with dithering — VERBATIM from dither.wgsl.
vec3 quantizeWithDither(vec3 color, float levelsArg, float ditherValue, float thresh) {
	float adjustedDither = ditherValue - 0.5 + thresh;
	vec3 dithered = color + adjustedDither / levelsArg;
	return floor(dithered * levelsArg) / (levelsArg - 1.0);
}

// Color distance in RGB space — VERBATIM from dither.wgsl (this effect's own copy).
float colorDistance(vec3 a, vec3 b) {
	vec3 diff = a - b;
	return dot(diff, diff);
}

// Palette color arrays — VERBATIM from dither.wgsl switch tables (if/else for Metal).
vec3 getDotMatrixGreen(int i) {
	if (i == 0) { return vec3(0.06, 0.22, 0.06); }
	else if (i == 1) { return vec3(0.19, 0.38, 0.19); }
	else if (i == 2) { return vec3(0.55, 0.67, 0.06); }
	else { return vec3(0.61, 0.74, 0.06); }
}

vec3 getAmber(int i) {
	if (i == 0) { return vec3(0.0, 0.0, 0.0); }
	else if (i == 1) { return vec3(0.4, 0.2, 0.0); }
	else if (i == 2) { return vec3(0.8, 0.4, 0.0); }
	else { return vec3(1.0, 0.6, 0.0); }
}

vec3 getCGA(int i) {
	if (i == 0) { return vec3(0.0, 0.0, 0.0); }
	else if (i == 1) { return vec3(0.0, 1.0, 1.0); }
	else if (i == 2) { return vec3(1.0, 0.0, 1.0); }
	else { return vec3(1.0, 1.0, 1.0); }
}

vec3 getPico8(int i) {
	if (i == 0) { return vec3(0.0, 0.0, 0.0); }
	else if (i == 1) { return vec3(0.114, 0.169, 0.325); }
	else if (i == 2) { return vec3(0.494, 0.145, 0.325); }
	else if (i == 3) { return vec3(0.0, 0.529, 0.318); }
	else if (i == 4) { return vec3(0.671, 0.322, 0.212); }
	else if (i == 5) { return vec3(0.373, 0.341, 0.310); }
	else if (i == 6) { return vec3(0.761, 0.765, 0.780); }
	else if (i == 7) { return vec3(1.0, 0.945, 0.910); }
	else if (i == 8) { return vec3(1.0, 0.0, 0.302); }
	else if (i == 9) { return vec3(1.0, 0.639, 0.0); }
	else if (i == 10) { return vec3(1.0, 0.925, 0.153); }
	else if (i == 11) { return vec3(0.0, 0.894, 0.212); }
	else if (i == 12) { return vec3(0.161, 0.678, 1.0); }
	else if (i == 13) { return vec3(0.514, 0.463, 0.612); }
	else if (i == 14) { return vec3(1.0, 0.467, 0.659); }
	else { return vec3(1.0, 0.8, 0.667); }
}

vec3 getC64(int i) {
	if (i == 0) { return vec3(0.0, 0.0, 0.0); }
	else if (i == 1) { return vec3(1.0, 1.0, 1.0); }
	else if (i == 2) { return vec3(0.533, 0.0, 0.0); }
	else if (i == 3) { return vec3(0.667, 1.0, 0.933); }
	else if (i == 4) { return vec3(0.8, 0.267, 0.8); }
	else if (i == 5) { return vec3(0.0, 0.8, 0.333); }
	else if (i == 6) { return vec3(0.0, 0.0, 0.667); }
	else if (i == 7) { return vec3(0.933, 0.933, 0.467); }
	else if (i == 8) { return vec3(0.867, 0.533, 0.333); }
	else if (i == 9) { return vec3(0.4, 0.267, 0.0); }
	else if (i == 10) { return vec3(1.0, 0.467, 0.467); }
	else if (i == 11) { return vec3(0.2, 0.2, 0.2); }
	else if (i == 12) { return vec3(0.467, 0.467, 0.467); }
	else if (i == 13) { return vec3(0.667, 1.0, 0.4); }
	else if (i == 14) { return vec3(0.0, 0.533, 1.0); }
	else { return vec3(0.6, 0.6, 0.6); }
}

vec3 getZXSpectrum(int i) {
	if (i == 0) { return vec3(0.0, 0.0, 0.0); }
	else if (i == 1) { return vec3(0.0, 0.0, 0.839); }
	else if (i == 2) { return vec3(0.839, 0.0, 0.0); }
	else if (i == 3) { return vec3(0.839, 0.0, 0.839); }
	else if (i == 4) { return vec3(0.0, 0.839, 0.0); }
	else if (i == 5) { return vec3(0.0, 0.839, 0.839); }
	else if (i == 6) { return vec3(0.839, 0.839, 0.0); }
	else if (i == 7) { return vec3(0.839, 0.839, 0.839); }
	else if (i == 8) { return vec3(0.0, 0.0, 1.0); }
	else if (i == 9) { return vec3(1.0, 0.0, 0.0); }
	else if (i == 10) { return vec3(1.0, 0.0, 1.0); }
	else if (i == 11) { return vec3(0.0, 1.0, 0.0); }
	else if (i == 12) { return vec3(0.0, 1.0, 1.0); }
	else if (i == 13) { return vec3(1.0, 1.0, 0.0); }
	else { return vec3(1.0, 1.0, 1.0); }
}

vec3 getAppleII(int i) {
	if (i == 0) { return vec3(0.0, 0.0, 0.0); }
	else if (i == 1) { return vec3(0.882, 0.0, 0.494); }
	else if (i == 2) { return vec3(0.247, 0.0, 0.682); }
	else if (i == 3) { return vec3(1.0, 0.0, 1.0); }
	else if (i == 4) { return vec3(0.0, 0.494, 0.263); }
	else if (i == 5) { return vec3(0.502, 0.502, 0.502); }
	else if (i == 6) { return vec3(0.0, 0.325, 1.0); }
	else if (i == 7) { return vec3(0.667, 0.671, 1.0); }
	else if (i == 8) { return vec3(0.502, 0.302, 0.0); }
	else if (i == 9) { return vec3(1.0, 0.467, 0.0); }
	else if (i == 10) { return vec3(0.502, 0.502, 0.502); }
	else if (i == 11) { return vec3(1.0, 0.616, 0.667); }
	else if (i == 12) { return vec3(0.0, 0.831, 0.0); }
	else if (i == 13) { return vec3(1.0, 1.0, 0.0); }
	else if (i == 14) { return vec3(0.333, 1.0, 0.557); }
	else { return vec3(1.0, 1.0, 1.0); }
}

vec3 getEGA(int i) {
	if (i == 0) { return vec3(0.0, 0.0, 0.0); }
	else if (i == 1) { return vec3(0.0, 0.0, 0.667); }
	else if (i == 2) { return vec3(0.0, 0.667, 0.0); }
	else if (i == 3) { return vec3(0.0, 0.667, 0.667); }
	else if (i == 4) { return vec3(0.667, 0.0, 0.0); }
	else if (i == 5) { return vec3(0.667, 0.0, 0.667); }
	else if (i == 6) { return vec3(0.667, 0.333, 0.0); }
	else if (i == 7) { return vec3(0.667, 0.667, 0.667); }
	else if (i == 8) { return vec3(0.333, 0.333, 0.333); }
	else if (i == 9) { return vec3(0.333, 0.333, 1.0); }
	else if (i == 10) { return vec3(0.333, 1.0, 0.333); }
	else if (i == 11) { return vec3(0.333, 1.0, 1.0); }
	else if (i == 12) { return vec3(1.0, 0.333, 0.333); }
	else if (i == 13) { return vec3(1.0, 0.333, 1.0); }
	else if (i == 14) { return vec3(1.0, 1.0, 0.333); }
	else { return vec3(1.0, 1.0, 1.0); }
}

// Find closest color in palette — VERBATIM from dither.wgsl. count defaults to 16
// with overrides (4 for dot-matrix/amber/CGA, 15 for ZX). minDist seed 999999.0.
vec3 findClosestPaletteColor(vec3 color, int paletteType) {
	if (paletteType == PALETTE_MONOCHROME) {
		float luma = dot(color, vec3(0.299, 0.587, 0.114));
		if (luma > 0.5) {
			return vec3(1.0);
		} else {
			return vec3(0.0);
		}
	}

	vec3 closest = vec3(0.0);
	float minDist = 999999.0;
	int count = 16;

	if (paletteType == PALETTE_DOT_MATRIX_GREEN || paletteType == PALETTE_AMBER || paletteType == PALETTE_CGA) {
		count = 4;
	} else if (paletteType == PALETTE_ZX_SPECTRUM) {
		count = 15;
	}

	for (int i = 0; i < count; i = i + 1) {
		vec3 palColor = vec3(0.0);

		if (paletteType == PALETTE_DOT_MATRIX_GREEN) {
			palColor = getDotMatrixGreen(i);
		} else if (paletteType == PALETTE_AMBER) {
			palColor = getAmber(i);
		} else if (paletteType == PALETTE_PICO8) {
			palColor = getPico8(i);
		} else if (paletteType == PALETTE_C64) {
			palColor = getC64(i);
		} else if (paletteType == PALETTE_CGA) {
			palColor = getCGA(i);
		} else if (paletteType == PALETTE_ZX_SPECTRUM) {
			palColor = getZXSpectrum(i);
		} else if (paletteType == PALETTE_APPLE_II) {
			palColor = getAppleII(i);
		} else if (paletteType == PALETTE_EGA) {
			palColor = getEGA(i);
		}

		float dist = colorDistance(color, palColor);
		if (dist < minDist) {
			minDist = dist;
			closest = palColor;
		}
	}

	return closest;
}

// Apply palette-based dithering — VERBATIM from dither.wgsl.
vec3 ditherWithPalette(vec3 color, float ditherValue, float thresh, int paletteType) {
	vec3 dithered = clamp(color + (ditherValue - 0.5 + thresh) * 0.25, vec3(0.0), vec3(1.0));
	return findClosestPaletteColor(dithered, paletteType);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	vec4 color = texture(inputTex, uv);

	// Get dither threshold for current pixel. matrixScale/threshold/time stay f32
	// (WGSL Uniforms types); ditherType/palette/levels narrowed to int at use.
	float ditherValue = getDitherThreshold(gl_FragCoord.xy, int(ditherType), matrixScale, time);

	vec3 result;

	if (int(palette) == PALETTE_INPUT) {
		// Per-channel quantization to the chosen number of levels
		result = quantizeWithDither(color.rgb, float(int(levels)), ditherValue, threshold);
	} else {
		// Use palette-based dithering
		result = ditherWithPalette(color.rgb, ditherValue, threshold, int(palette));
	}

	// Blend between original input and dithered result
	result = mix(color.rgb, result, mixAmount);

	frag = vec4(result, color.a);
}

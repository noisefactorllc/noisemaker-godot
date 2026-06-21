#version 450
// classicNoisedeck/noise (Noise) — LEGACY Noisedeck animated multi-resolution noise
// synthesizer. Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/noise/wgsl/noise.wgsl
// (cross-checked against the HLSL port's classicNoisedeck/Noise).
//
// Single render pass (program "noise"). Generator (no texture inputs). Top-left
// origin (Godot/Vulkan, matches WGSL) — NO per-effect Y-flip; the runtime applies
// the single global flip.
//
// NOISE_TYPE, COLOR_MODE, REFRACT_MODE, LOOP_OFFSET and METRIC are compile-time
// integer #defines injected by the runtime from the graph's `defines` (see
// noise.json globals.*.define). Kept here as bare identifiers; never declared or
// hardcoded. When a helper takes an int, narrow at the call site (value is integral).
//
// pcg/prng/random/map/periodicFunction/positiveModulo come from nm_core (bit-exact,
// byte-identical to this effect's own versions). All other helpers — hsv/rgb,
// distance metrics, shape, kaleidoscope, oklab, palette, the noise variants — are
// this effect's OWN versions, inlined verbatim. Packed uniformLayout: vec4 data[12]
// (effects/classicNoisedeck/noise.json; max slot 11 -> 12 vec4s).
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[12]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// WGSL var<private> globals — set from data[] in main(), read by helper functions.
vec2 resolution;
float time;
float aspectRatio;
float xScale;
float yScale;
float seed;
float loopScale;
float speed;
int octaves;
bool ridges;
bool wrap;
int paletteMode;
float refractAmt;
float kaleido;
int cyclePalette;
float rotatePalette;
float repeatPalette;
float hueRange;
float hueRotation;
vec3 paletteOffset;
vec3 paletteAmp;
vec3 paletteFreq;
vec3 palettePhase;

// Full-precision PI/TAU exactly as the WGSL declares them.
const float NMN_PI = 3.14159265359;
const float NMN_TAU = 6.28318530718;

float blendBicubic(float p0, float p1, float p2, float p3, float t) {
	float t2 = t * t;
	float t3 = t2 * t;

	float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
	float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
	float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
	float b3 = t3 / 6.0;

	return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

float catmullRom3(float p0, float p1, float p2, float t) {
	float t2 = t * t;
	float t3 = t2 * t;

	return p1 + 0.5 * t * (p2 - p0) +
	       0.5 * t2 * (2.0*p0 - 5.0*p1 + 4.0*p2 - p0) +
	       0.5 * t3 * (-p0 + 3.0*p1 - 3.0*p2 + p0);
}

float catmullRom4(float p0, float p1, float p2, float p3, float t) {
	return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 +
	       t * (3.0 * (p1 - p2) + p3 - p0)));
}

float blendLinearOrCosine(float a, float b, float amount, int interp) {
	if (interp == 1) {
		return mix(a, b, amount);
	}
	return mix(a, b, smoothstep(0.0, 1.0, amount));
}

float constantFromLatticeWithOffset(vec2 lattice_in, vec2 freq, float s, float blend, ivec2 offset) {
	vec2 baseFloor = floor(lattice_in);
	ivec2 cell = ivec2(int(baseFloor.x), int(baseFloor.y)) + offset;
	vec2 frac = lattice_in - baseFloor;

	int seedInt = int(floor(s));
	float sFrac = fract(s);

	float xCombined = frac.x + sFrac;
	int xi = cell.x + int(floor(xCombined));
	int yi = cell.y;

	if (wrap) {
		int freqX = int(freq.x + 0.5);
		int freqY = int(freq.y + 0.5);

		if (freqX > 0) {
			xi = positiveModulo(xi, freqX);
		}
		if (freqY > 0) {
			yi = positiveModulo(yi, freqY);
		}
	}

	uint xBits = uint(xi);
	uint yBits = uint(yi);
	uint seedBits = uint(seedInt);
	uint fracBits = floatBitsToUint(sFrac);

	uvec3 jitter = uvec3(
		(fracBits * 374761393u) ^ 0x9E3779B9u,
		(fracBits * 668265263u) ^ 0x7F4A7C15u,
		(fracBits * 2246822519u) ^ 0x94D049B4u
	);

	uvec3 prngState = pcg(uvec3(xBits, yBits, seedBits) ^ jitter);
	float noiseValue = float(prngState.x) / float(0xffffffffu);

	return periodicFunction(noiseValue - blend);
}

// WGSL `constant` renamed (MSL address-space keyword) — pure symbol rename.
float constantValue(vec2 st_in, vec2 freq, float s, float blend) {
	vec2 lattice = st_in * freq;
	return constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2(0, 0));
}

float constantOffset(vec2 lattice, vec2 freq, float s, float blend, ivec2 offset) {
	return constantFromLatticeWithOffset(lattice, freq, s, blend, offset);
}

vec3 mod289_3(vec3 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec2 mod289_2(vec2 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec3 permute3(vec3 x) {
	return mod289_3(((x * 34.0) + 1.0) * x);
}

float quadratic3(float p0, float p1, float p2, float t) {
	float t2 = t * t;

	return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
	       p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
	       p2 * 0.5 * t2;
}

float cubic3x3ValueNoise(vec2 st, vec2 freq, float s, float blend) {
	vec2 lattice = st * freq;
	vec2 f = fract(lattice);

	float v00 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2(-1, -1));
	float v10 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2( 0, -1));
	float v20 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2( 1, -1));

	float v01 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2(-1,  0));
	float v11 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2( 0,  0));
	float v21 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2( 1,  0));

	float v02 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2(-1,  1));
	float v12 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2( 0,  1));
	float v22 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2( 1,  1));

	float y0 = quadratic3(v00, v10, v20, f.x);
	float y1 = quadratic3(v01, v11, v21, f.x);
	float y2 = quadratic3(v02, v12, v22, f.x);

	return quadratic3(y0, y1, y2, f.y);
}

float bicubicValue(vec2 st, vec2 freq, float s, float blend) {
	vec2 lattice = st * freq;

	float x0y0 = constantOffset(lattice, freq, s, blend, ivec2(-1, -1));
	float x0y1 = constantOffset(lattice, freq, s, blend, ivec2(-1, 0));
	float x0y2 = constantOffset(lattice, freq, s, blend, ivec2(-1, 1));
	float x0y3 = constantOffset(lattice, freq, s, blend, ivec2(-1, 2));

	float x1y0 = constantOffset(lattice, freq, s, blend, ivec2(0, -1));
	float x1y1 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2(0, 0));
	float x1y2 = constantOffset(lattice, freq, s, blend, ivec2(0, 1));
	float x1y3 = constantOffset(lattice, freq, s, blend, ivec2(0, 2));

	float x2y0 = constantOffset(lattice, freq, s, blend, ivec2(1, -1));
	float x2y1 = constantOffset(lattice, freq, s, blend, ivec2(1, 0));
	float x2y2 = constantOffset(lattice, freq, s, blend, ivec2(1, 1));
	float x2y3 = constantOffset(lattice, freq, s, blend, ivec2(1, 2));

	float x3y0 = constantOffset(lattice, freq, s, blend, ivec2(2, -1));
	float x3y1 = constantOffset(lattice, freq, s, blend, ivec2(2, 0));
	float x3y2 = constantOffset(lattice, freq, s, blend, ivec2(2, 1));
	float x3y3 = constantOffset(lattice, freq, s, blend, ivec2(2, 2));

	vec2 frac = fract(lattice);

	float y0 = blendBicubic(x0y0, x1y0, x2y0, x3y0, frac.x);
	float y1 = blendBicubic(x0y1, x1y1, x2y1, x3y1, frac.x);
	float y2 = blendBicubic(x0y2, x1y2, x2y2, x3y2, frac.x);
	float y3 = blendBicubic(x0y3, x1y3, x2y3, x3y3, frac.x);

	return blendBicubic(y0, y1, y2, y3, frac.y);
}

float catmullRom3x3ValueNoise(vec2 st, vec2 freq, float s, float blend) {
	vec2 lattice = vec2(st.x * freq.x + s, st.y * freq.y);

	float x0y0 = constantOffset(lattice, freq, s, blend, ivec2(-1, -1));
	float x0y1 = constantOffset(lattice, freq, s, blend, ivec2(-1, 0));
	float x0y2 = constantOffset(lattice, freq, s, blend, ivec2(-1, 1));

	float x1y0 = constantOffset(lattice, freq, s, blend, ivec2(0, -1));
	float x1y1 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2(0, 0));
	float x1y2 = constantOffset(lattice, freq, s, blend, ivec2(0, 1));

	float x2y0 = constantOffset(lattice, freq, s, blend, ivec2(1, -1));
	float x2y1 = constantOffset(lattice, freq, s, blend, ivec2(1, 0));
	float x2y2 = constantOffset(lattice, freq, s, blend, ivec2(1, 1));

	vec2 frac = fract(lattice);

	float y0 = catmullRom3(x0y0, x1y0, x2y0, frac.x);
	float y1 = catmullRom3(x0y1, x1y1, x2y1, frac.x);
	float y2 = catmullRom3(x0y2, x1y2, x2y2, frac.x);

	return catmullRom3(y0, y1, y2, frac.y);
}

float catmullRom4x4ValueNoise(vec2 st, vec2 freq, float s, float blend) {
	vec2 lattice = vec2(st.x * freq.x + s, st.y * freq.y);

	float x0y0 = constantOffset(lattice, freq, s, blend, ivec2(-1, -1));
	float x0y1 = constantOffset(lattice, freq, s, blend, ivec2(-1, 0));
	float x0y2 = constantOffset(lattice, freq, s, blend, ivec2(-1, 1));
	float x0y3 = constantOffset(lattice, freq, s, blend, ivec2(-1, 2));

	float x1y0 = constantOffset(lattice, freq, s, blend, ivec2(0, -1));
	float x1y1 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2(0, 0));
	float x1y2 = constantOffset(lattice, freq, s, blend, ivec2(0, 1));
	float x1y3 = constantOffset(lattice, freq, s, blend, ivec2(0, 2));

	float x2y0 = constantOffset(lattice, freq, s, blend, ivec2(1, -1));
	float x2y1 = constantOffset(lattice, freq, s, blend, ivec2(1, 0));
	float x2y2 = constantOffset(lattice, freq, s, blend, ivec2(1, 1));
	float x2y3 = constantOffset(lattice, freq, s, blend, ivec2(1, 2));

	float x3y0 = constantOffset(lattice, freq, s, blend, ivec2(2, -1));
	float x3y1 = constantOffset(lattice, freq, s, blend, ivec2(2, 0));
	float x3y2 = constantOffset(lattice, freq, s, blend, ivec2(2, 1));
	float x3y3 = constantOffset(lattice, freq, s, blend, ivec2(2, 2));

	vec2 frac = fract(lattice);

	float y0 = catmullRom4(x0y0, x1y0, x2y0, x3y0, frac.x);
	float y1 = catmullRom4(x0y1, x1y1, x2y1, x3y1, frac.x);
	float y2 = catmullRom4(x0y2, x1y2, x2y2, x3y2, frac.x);
	float y3 = catmullRom4(x0y3, x1y3, x2y3, x3y3, frac.x);

	return catmullRom4(y0, y1, y2, y3, frac.y);
}

float simplexValue(vec2 st_in, vec2 freq, float s, float blend) {
	const vec4 C = vec4(
		0.211324865405187,
		0.366025403784439,
		-0.577350269189626,
		0.024390243902439
	);

	vec2 uv = vec2(st_in.x * freq.x, st_in.y * freq.y);
	uv.x = uv.x + s;

	vec2 i = floor(uv + dot(uv, C.yy));
	vec2 x0 = uv - i + dot(i, C.xx);

	vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
	vec2 x1 = x0 - i1 + vec2(C.x, C.x);
	vec2 x2 = x0 - vec2(1.0, 1.0) + vec2(2.0 * C.x, 2.0 * C.x);

	i = mod289_2(i);
	vec3 p = permute3(permute3(i.y + vec3(0.0, i1.y, 1.0)) + i.x + vec3(0.0, i1.x, 1.0));

	vec3 m = max(vec3(0.5) - vec3(dot(x0, x0), dot(x1, x1), dot(x2, x2)), vec3(0.0));
	m = m * m;
	m = m * m;

	vec3 x = 2.0 * fract(p * C.www) - 1.0;
	vec3 h = abs(x) - 0.5;
	vec3 ox = floor(x + 0.5);
	vec3 a0 = x - ox;

	m = m * (1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h));

	vec3 g = vec3(0.0);
	g.x = a0.x * x0.x + h.x * x0.y;
	vec2 gyz = a0.yz * vec2(x1.x, x2.x) + h.yz * vec2(x1.y, x2.y);
	g.y = gyz.x;
	g.z = gyz.y;

	float v = 130.0 * dot(m, g);
	return periodicFunction(map(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

float sineNoise(vec2 st_in, vec2 freq, float s, float blend) {
	vec2 st = st_in * freq;
	st.x = st.x + s;

	float a = blend;
	float b = blend;
	float c = 1.0 - blend;

	vec3 r1 = prng(vec3(s, s, s)) * 0.75 + vec3(0.125, 0.125, 0.125);
	vec3 r2 = prng(vec3(s + 10.0, s + 10.0, s + 10.0)) * 0.75 + vec3(0.125, 0.125, 0.125);
	float x = sin(r1.x * st.y + sin(r1.y * st.x + a) + sin(r1.z * st.x + b) + c);
	float y = sin(r2.x * st.x + sin(r2.y * st.y + b) + sin(r2.z * st.y + c) + a);
	return (x + y) * 0.5 + 0.5;
}

float value(vec2 st, vec2 freq, float s, float blend) {
	if (NOISE_TYPE == 3) {
		return catmullRom3x3ValueNoise(st, freq, s, blend);
	} else if (NOISE_TYPE == 4) {
		return catmullRom4x4ValueNoise(st, freq, s, blend);
	} else if (NOISE_TYPE == 5) {
		return cubic3x3ValueNoise(st, freq, s, blend);
	} else if (NOISE_TYPE == 6) {
		return bicubicValue(st, freq, s, blend);
	} else if (NOISE_TYPE == 10) {
		return simplexValue(st, freq, s, blend);
	} else if (NOISE_TYPE == 11) {
		return sineNoise(st, freq, s, blend);
	}

	vec2 lattice = st * freq;
	float x1y1 = constantFromLatticeWithOffset(lattice, freq, s, blend, ivec2(0, 0));
	if (NOISE_TYPE == 0) {
		return x1y1;
	}

	float x2y1 = constantOffset(lattice, freq, s, blend, ivec2(1, 0));
	float x1y2 = constantOffset(lattice, freq, s, blend, ivec2(0, 1));
	float x2y2 = constantOffset(lattice, freq, s, blend, ivec2(1, 1));

	vec2 frac = fract(lattice);
	float a = blendLinearOrCosine(x1y1, x2y1, frac.x, int(NOISE_TYPE));
	float b = blendLinearOrCosine(x1y2, x2y2, frac.x, int(NOISE_TYPE));
	return blendLinearOrCosine(a, b, frac.y, int(NOISE_TYPE));
}

float circles(vec2 st, float freq) {
	float dist = length(st - vec2(0.5 * aspectRatio, 0.5));
	return dist * freq;
}

float rings(vec2 st, float freq) {
	float dist = length(st - vec2(0.5 * aspectRatio, 0.5));
	return cos(dist * NMN_PI * freq);
}

float diamonds(vec2 st_in, float freq) {
	vec2 st = st_in - vec2(0.5 * aspectRatio, 0.5);
	st = st * freq;
	return cos(st.x * NMN_PI) + cos(st.y * NMN_PI);
}

// WGSL atan2(st.x, st.y) — arg order copied LITERALLY.
float shape(vec2 st_in, int sides, float blend) {
	vec2 st = st_in * 2.0 - vec2(aspectRatio, 1.0);
	float a = atan(st.x, st.y) + NMN_PI;
	float r = NMN_TAU / float(sides);
	return cos(floor(0.5 + a / r) * r - a) * length(st) * blend;
}

float getMetric(vec2 st_in) {
	vec2 st = st_in;
	vec2 diff = vec2(0.5 * aspectRatio, 0.5) - st;
	float r = 1.0;
	if (METRIC == 0) {
		r = length(st - vec2(0.5 * aspectRatio, 0.5));
	} else if (METRIC == 1) {
		r = abs(diff.x) + abs(diff.y);
	} else if (METRIC == 2) {
		r = max(max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y), max(abs(diff.x) - diff.y * 0.5, diff.y));
	} else if (METRIC == 3) {
		r = max((abs(diff.x) + abs(diff.y)) / sqrt(2.0), max(abs(diff.x), abs(diff.y)));
	} else if (METRIC == 4) {
		r = max(abs(diff.x), abs(diff.y));
	} else if (METRIC == 5) {
		r = max(abs(diff.x) - diff.y * -0.5, -1.0 * diff.y);
	}
	return r;
}

// WGSL mat2x2<f32>(c,-s,s,c) is column-major; GLSL mat2(c,-s,s,c) is too -> M*v identical.
vec2 rotate2D(vec2 st, float rot) {
	float angle = rot * NMN_PI;
	float c = cos(angle);
	float s = sin(angle);
	return mat2(c, -s, s, c) * st;
}

// WGSL atan2(st.y, st.x) — arg order copied LITERALLY.
vec2 kaleidoscope(vec2 st_in, float sides, float blendy) {
	if (sides == 1.0) {
		return st_in;
	}
	float r = getMetric(st_in) + blendy;
	vec2 st = st_in - vec2(0.5 * aspectRatio, 0.5);
	st = rotate2D(st, 0.5);
	float a = atan(st.y, st.x);
	float ma = abs(mod(a - radians(360.0 / sides), NMN_TAU / sides) - NMN_PI / sides);
	return r * vec2(cos(ma), sin(ma));
}

vec3 hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float h6 = h * 6.0;
	float k = h6 - 2.0 * floor(h6 / 2.0);
	float x = c * (1.0 - abs(k - 1.0));
	float m = v - c;

	vec3 rgb = vec3(0.0);
	if (h6 < 1.0) {
		rgb = vec3(c, x, 0.0);
	} else if (h6 < 2.0) {
		rgb = vec3(x, c, 0.0);
	} else if (h6 < 3.0) {
		rgb = vec3(0.0, c, x);
	} else if (h6 < 4.0) {
		rgb = vec3(0.0, x, c);
	} else if (h6 < 5.0) {
		rgb = vec3(x, 0.0, c);
	} else {
		rgb = vec3(c, 0.0, x);
	}
	return rgb + vec3(m, m, m);
}

vec3 rgb2hsv(vec3 rgb) {
	float r = rgb.x;
	float g = rgb.y;
	float b = rgb.z;
	float maxc = max(r, max(g, b));
	float minc = min(r, min(g, b));
	float delta = maxc - minc;

	float h = 0.0;
	if (delta != 0.0) {
		if (maxc == r) {
			h = mod((g - b) / delta, 6.0) / 6.0;
		} else if (maxc == g) {
			h = ((b - r) / delta + 2.0) / 6.0;
		} else {
			h = ((r - g) / delta + 4.0) / 6.0;
		}
	}

	float s = (maxc == 0.0) ? 0.0 : delta / maxc;
	float v = maxc;
	return vec3(h, s, v);
}

vec3 linearToSrgb(vec3 linear) {
	vec3 srgb = vec3(0.0);
	for (int i = 0; i < 3; i = i + 1) {
		if (linear[i] <= 0.0031308) {
			srgb[i] = linear[i] * 12.92;
		} else {
			srgb[i] = 1.055 * pow(linear[i], 1.0 / 2.4) - 0.055;
		}
	}
	return srgb;
}

vec3 srgbToLinear(vec3 srgb) {
	vec3 linear = vec3(0.0);
	for (int i = 0; i < 3; i = i + 1) {
		if (srgb[i] <= 0.04045) {
			linear[i] = srgb[i] / 12.92;
		} else {
			linear[i] = pow((srgb[i] + 0.055) / 1.055, 2.4);
		}
	}
	return linear;
}

// WGSL mat3x3<f32> constructor takes COLUMNS; GLSL mat3(c0,c1,c2) is also column-major,
// so M*c == col0*c.x + col1*c.y + col2*c.z, identical to the WGSL.
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

const mat3 invB = mat3(
	vec3(0.4121656120, 0.2118591070, 0.0883097947),
	vec3(0.5362752080, 0.6807189584, 0.2818474174),
	vec3(0.0514575653, 0.1074065790, 0.6302613616)
);

const mat3 invA = mat3(
	vec3(0.2104542553, 1.9779984951, 0.0259040371),
	vec3(0.7936177850, -2.4285922050, 0.7827717662),
	vec3(-0.0040720468, 0.4505937099, -0.8086757660)
);

vec3 oklab_from_linear_srgb(vec3 c) {
	vec3 lms = invB * c;
	return invA * (sign(lms) * pow(abs(lms), vec3(0.3333333333333)));
}

vec3 linear_srgb_from_oklab(vec3 c) {
	vec3 lms = fwdA * c;
	return fwdB * (lms * lms * lms);
}

vec3 pal(float t_in) {
	float t = t_in * repeatPalette + rotatePalette * 0.01;
	vec3 color = paletteOffset + paletteAmp * cos(6.28318 * (paletteFreq * t + palettePhase));

	if (paletteMode == 1) {
		color = hsv2rgb(color);
	} else if (paletteMode == 2) {
		color.y = color.y * -0.509 + 0.276;
		color.z = color.z * -0.509 + 0.198;
		color = linear_srgb_from_oklab(color);
		color = linearToSrgb(color);
	}

	return color;
}

vec3 generate_octave(vec2 st, vec2 freq, float s, float blend, float octave) {
	vec3 layer = vec3(
		value(st, freq, seed + 10.0 * octave, blend),
		value(st, freq, seed + 20.0 * octave, blend),
		value(st, freq, seed + 30.0 * octave, blend)
	);
	if (ridges && COLOR_MODE == 6) {
		layer.z = 1.0 - abs(layer.z * 2.0 - 1.0);
	}
	return layer;
}

vec3 multires(vec2 st_in, vec2 freq, int oct, float s, float blend) {
	vec2 st = st_in;
	vec3 color = vec3(0.0);
	float multiplicand = 0.0;
	vec2 nominalFreq = vec2(0.0, 0.0);
	if (NOISE_TYPE == 11) {
		// Sine noise uses [40, 1]; pin refract defaults to its midpoint.
		float base = map(75.0, 1.0, 100.0, 40.0, 1.0);
		nominalFreq = vec2(base, base);
	} else if (NOISE_TYPE == 10) {
		// Simplex spans [6, 0.5]; keep axis ratios anchored to that midpoint.
		float base = map(75.0, 1.0, 100.0, 6.0, 0.5);
		nominalFreq = vec2(base, base);
	} else {
		// Value-noise flavours share [20, 3]; reuse midpoint for balanced distortion.
		float base = map(75.0, 1.0, 100.0, 20.0, 3.0);
		nominalFreq = vec2(base, base);
	}

	int total = max(oct, 1);
	for (int i = 1; i <= total; i = i + 1) {
		float multiplier = pow(2.0, float(i));
		vec2 baseFreq = freq * 0.5 * multiplier;
		float nominalBase = nominalFreq.x * 0.5 * multiplier;
		multiplicand = multiplicand + 1.0 / multiplier;

		if (REFRACT_MODE == 1 || REFRACT_MODE == 2) {
			vec2 xRefractFreq = vec2(baseFreq.x, nominalBase);
			vec2 yRefractFreq = vec2(nominalBase, baseFreq.y);
			float xRef = value(st, xRefractFreq, s + 10.0 * float(i), blend) - 0.5;
			float yRef = value(st, yRefractFreq, s + 20.0 * float(i), blend) - 0.5;
			float refraction = map(refractAmt, 0.0, 100.0, 0.0, 1.0) / multiplier;
			st = vec2(st.x + xRef * refraction, st.y + yRef * refraction);
		}

		vec3 layer = generate_octave(st, baseFreq, s + 10.0 * float(i), blend, float(i));

		if (REFRACT_MODE == 0 || REFRACT_MODE == 2) {
			float xOff = cos(layer.z) * 0.5 + 0.5;
			float yOff = sin(layer.z) * 0.5 + 0.5;
			vec3 refLayer = generate_octave(vec2(st.x + xOff, st.y + yOff), baseFreq, s + 15.0 * float(i), blend, float(i));
			float amt = map(refractAmt, 0.0, 100.0, 0.0, 1.0);
			layer = mix(layer, refLayer, vec3(amt));
		}

		color = color + layer / multiplier;
	}

	color = color / multiplicand;

	vec3 result = color;
	if (COLOR_MODE == 0) {
		if (ridges) {
			result.z = 1.0 - abs(result.z * 2.0 - 1.0);
		}
		result = vec3(result.z);
	} else if (COLOR_MODE == 1) {
		result = srgbToLinear(result);
	} else if (COLOR_MODE == 2) {
		// srgb, no change
	} else if (COLOR_MODE == 3) {
		result.y = result.y * -0.509 + 0.276;
		result.z = result.z * -0.509 + 0.198;
		result = linear_srgb_from_oklab(result);
		result = linearToSrgb(result);
	} else if (COLOR_MODE == 4) {
		if (ridges) {
			result.z = 1.0 - abs(result.z * 2.0 - 1.0);
		}
		float d = result.z;
		if (cyclePalette == -1) {
			d = d + time;
		} else if (cyclePalette == 1) {
			d = d - time;
		}
		result = pal(d);
	} else {
		vec3 hsv = result;
		hsv.x = hsv.x * hueRange * 0.01;
		hsv.x = hsv.x + 1.0 - (hueRotation / 360.0);
		result = hsv2rgb(hsv);
	}

	if (COLOR_MODE != 4 && COLOR_MODE != 6) {
		vec3 hsv = rgb2hsv(result);
		hsv.x = hsv.x + 1.0 - (hueRotation / 360.0);
		hsv.x = fract(hsv.x);
		if (ridges && (COLOR_MODE == 1 || COLOR_MODE == 2 || COLOR_MODE == 3)) {
			hsv.z = 1.0 - abs(hsv.z * 2.0 - 1.0);
		}
		result = hsv2rgb(hsv);
	}

	return result;
}

float offset(vec2 st_in, vec2 freq) {
	if (LOOP_OFFSET == 10) {
		return circles(st_in, freq.x);
	} else if (LOOP_OFFSET == 20) {
		return shape(st_in, 3, freq.x * 0.5);
	} else if (LOOP_OFFSET == 30) {
		return (abs(st_in.x - 0.5 * aspectRatio) + abs(st_in.y - 0.5)) * freq.x * 0.5;
	} else if (LOOP_OFFSET == 40) {
		return shape(st_in, 4, freq.x * 0.5);
	} else if (LOOP_OFFSET == 50) {
		return shape(st_in, 5, freq.x * 0.5);
	} else if (LOOP_OFFSET == 60) {
		return shape(st_in, 6, freq.x * 0.5);
	} else if (LOOP_OFFSET == 70) {
		return shape(st_in, 7, freq.x * 0.5);
	} else if (LOOP_OFFSET == 80) {
		return shape(st_in, 8, freq.x * 0.5);
	} else if (LOOP_OFFSET == 90) {
		return shape(st_in, 9, freq.x * 0.5);
	} else if (LOOP_OFFSET == 100) {
		return shape(st_in, 10, freq.x * 0.5);
	} else if (LOOP_OFFSET == 110) {
		return shape(st_in, 11, freq.x * 0.5);
	} else if (LOOP_OFFSET == 120) {
		return shape(st_in, 12, freq.x * 0.5);
	} else if (LOOP_OFFSET == 200) {
		return st_in.x * freq.x * 0.5;
	} else if (LOOP_OFFSET == 210) {
		return st_in.y * freq.x * 0.5;
	} else if (LOOP_OFFSET == 300) {
		vec2 st = st_in - vec2(aspectRatio * 0.5, 0.5);
		return value(st, freq, seed + 50.0, 0.0);
	} else if (LOOP_OFFSET == 400) {
		return 1.0 - rings(st_in, freq.x);
	} else if (LOOP_OFFSET == 410) {
		return 1.0 - diamonds(st_in, freq.x);
	}
	return 0.0;
}

void main() {
	resolution = data[0].xy;
	time = data[0].z;
	aspectRatio = data[0].w;
	xScale = data[1].x;
	yScale = data[1].y;
	seed = data[1].z;
	loopScale = data[1].w;
	speed = data[2].x;
	// data[2].y was loopOffset (now compile-time LOOP_OFFSET)
	octaves = max(1, int(data[2].w));
	ridges = data[3].x > 0.5;
	wrap = data[3].y > 0.5;
	// data[3].z was refractMode (now compile-time REFRACT_MODE)
	refractAmt = data[3].w;
	kaleido = data[4].x;
	// data[4].y was metric (now compile-time METRIC)
	// data[4].z was colorMode (now compile-time COLOR_MODE)
	paletteMode = int(data[4].w);
	cyclePalette = int(data[5].x);
	rotatePalette = data[5].y;
	repeatPalette = data[5].z;
	hueRange = data[5].w;
	hueRotation = data[6].x;
	paletteOffset = data[7].xyz;
	paletteAmp = data[8].xyz;
	paletteFreq = data[9].xyz;
	palettePhase = data[10].xyz;

	vec2 tileOffset = data[11].xy;
	vec2 fullResolution = data[11].zw;
	vec2 st = (gl_FragCoord.xy + tileOffset) / fullResolution.y;
	st = kaleidoscope(st, kaleido, 0.5);
	vec2 centered = st - vec2(aspectRatio * 0.5, 0.5);

	vec2 freq = vec2(1.0, 1.0);
	vec2 lf = vec2(1.0, 1.0);

	if (NOISE_TYPE == 11) {
		freq.x = map(xScale, 1.0, 100.0, 40.0, 1.0);
		freq.y = map(yScale, 1.0, 100.0, 40.0, 1.0);
		float val = map(loopScale, 1.0, 100.0, 10.0, 1.0);
		lf = vec2(val, val);
	} else if (NOISE_TYPE == 10) {
		freq.x = map(xScale, 1.0, 100.0, 6.0, 0.5);
		freq.y = map(yScale, 1.0, 100.0, 6.0, 0.5);
		float val = map(loopScale, 1.0, 100.0, 6.0, 0.5);
		lf = vec2(val, val);
	} else {
		freq.x = map(xScale, 1.0, 100.0, 20.0, 3.0);
		freq.y = map(yScale, 1.0, 100.0, 20.0, 3.0);
		float val = map(loopScale, 1.0, 100.0, 12.0, 3.0);
		lf = vec2(val, val);
	}

	if (LOOP_OFFSET == 300) {
		vec2 nominalFreq = vec2(1.0, 1.0);
		if (NOISE_TYPE == 11) {
			// Sine noise maps into a wide [40, 1] range, so reuse its midpoint to match the field frequency.
			float base = map(75.0, 1.0, 100.0, 40.0, 1.0);
			nominalFreq = vec2(base, base);
		} else if (NOISE_TYPE == 10) {
			// Simplex maps into [6, 0.5]; anchoring to its midpoint keeps loop stretch aligned with the main noise.
			float base = map(75.0, 1.0, 100.0, 6.0, 0.5);
			nominalFreq = vec2(base, base);
		} else {
			// All other value-noise flavours share the [20, 3] range, so lock to that midpoint.
			float base = map(75.0, 1.0, 100.0, 20.0, 3.0);
			nominalFreq = vec2(base, base);
		}
		// Mirror the main noise's per-axis stretch without cross-coupling sliders.
		lf = lf * (freq / nominalFreq);
	}

	if (NOISE_TYPE != 4 && NOISE_TYPE != 10 && wrap) {
		freq = floor(freq);
		if (LOOP_OFFSET == 300) {
			lf = floor(lf);
		}
	}

	float t = 1.0;
	if (speed < 0.0) {
		t = time + offset(st, lf);
	} else {
		t = time - offset(st, lf);
	}
	float blend = periodicFunction(t) * abs(speed) * 0.01;

	vec3 colorRgb = multires(centered, freq, octaves, seed, blend);
	frag = vec4(colorRgb, 1.0);
}

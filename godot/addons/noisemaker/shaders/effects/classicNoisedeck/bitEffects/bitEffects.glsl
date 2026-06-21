#version 450
// classicNoisedeck/bitEffects — ported PIXEL-IDENTICALLY for Godot RenderingDevice.
// Top-left origin (Godot/Vulkan, matches WGSL) — NO Y-flip. Generator, no inputs.
// Bit field + bit mask generator. Single render pass ("bitEffects").
//
// SOURCE STRATEGY (mirrors the validated HLSL port):
//   Structure ported from wgsl/bitEffects.wgsl, BUT the value-noise hash is taken
//   from the GLSL golden (glsl/bitEffects.glsl `randomFromLatticeWithOffset`). The
//   parity golden is rendered by the WebGL2 = GLSL backend, and the WGSL diverges:
//   its `constant` uses a SIMPLIFIED hash `prng(floor(vec3(st*freq + s, 0)))` that
//   does NOT match the GLSL reference. `constant` is on the critical path for BOTH
//   modes (bitMask interior cells via maskValue, bitField blendy via value), so the
//   GLSL hash governs the whole pattern. The simple WGSL `prng` is kept inline for
//   structural fidelity (unused, as in the GLSL golden).
//
// uniformLayout PRESENT (effects/classicNoisedeck/bitEffects.json, max slot 5) →
//   declare own UBO: vec4 data[6]. MODE/FORMULA/COLOR_SCHEME/INTERP/MASK_FORMULA/
//   MASK_COLOR_SCHEME are compile-time #defines injected by the backend after #version
//   (graph pass `defines`); kept as bare identifiers, never declared/hardcoded.
//
// VERBATIM PER-EFFECT HELPERS (do NOT substitute nm_core versions; no include):
//   * this effect's periodicFunction uses SIN: map(sin(p*TAU),-1,1,0,1) — nm_core's
//     uses COS. Inlined here. PI/TAU are the WGSL's full-precision literals.
//   * pcg/prng are the plain uvec3(p) TRUNCATION variant (NOT nm_core's sign-fold).
//   * `constant` → renamed `constantValue` (MSL reserved keyword; Metal stage fails
//     otherwise — see PORTING-GUIDE macOS gotcha, same fix as synth/shape).
//   * 8-bit masked integer ops (modi/or_i/and_i/not_i/xor_i) reproduced exactly with
//     & | ^ ~ and int()/uint() truncation casts.
//   * rotate2D / bitMask aspectRatio reference the WGSL private `resolution` (ported
//     literally per golden rule 1). In the parity harness resolution == fullResolution
//     (nm_backend `_engine_value`), so this matches the GLSL golden's fullResolution.
//   * WGSL select(falseVal, trueVal, cond) → (cond) ? trueVal : falseVal.
//   * f32(boolExpr) → (boolExpr) ? 1.0 : 0.0.

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[6]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// WGSL private vars — set from data[] in main(), read by the helpers below.
float time;
float seed;
vec2 resolution;
float n;
float scale;
float rotation;
float speed;
float tiles;
float complexity;
float hueRange;
float hueRotation;
float baseHueRange;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

float map(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

uvec3 pcg(uvec3 v_in) {
	uvec3 v = v_in * 1664525u + 1013904223u;

	v.x = v.x + v.y * v.z;
	v.y = v.y + v.z * v.x;
	v.z = v.z + v.x * v.y;

	v.x = v.x ^ (v.x >> 16u);
	v.y = v.y ^ (v.y >> 16u);
	v.z = v.z ^ (v.z >> 16u);

	v.x = v.x + v.y * v.z;
	v.y = v.y + v.z * v.x;
	v.z = v.z + v.x * v.y;

	return v;
}

// Simple WGSL prng (uvec3(p) truncation, /float(0xffffffffu)). Kept for structural
// fidelity; the active hash is randomFromLatticeWithOffset (GLSL golden) below.
vec3 prng(vec3 p) {
	return vec3(pcg(uvec3(p))) / float(0xffffffffu);
}

vec2 rotate2D(vec2 st, float rot) {
	vec2 st2 = st;
	float angle = map(rot, 0.0, 360.0, 0.0, 1.0) * TAU;
	st2 = st2 - resolution * 0.5;
	float c = cos(angle);
	float s = sin(angle);
	mat2 m = mat2(c, -s, s, c);
	st2 = m * st2;
	st2 = st2 + resolution * 0.5;
	return st2;
}

// SIN variant — this effect's own periodicFunction (NOT nm_core's cos).
float periodicFunction(float p) {
	return map(sin(p * TAU), -1.0, 1.0, 0.0, 1.0);
}

// Value-noise hash — ported VERBATIM from the GLSL golden randomFromLatticeWithOffset.
// Folds the seed into the integer lattice and derives PCG jitter from
// floatBitsToUint(fract(seed)). This is the parity-critical override of the WGSL hash.
vec3 randomFromLatticeWithOffset(vec2 st, float xFreq, float yFreq, float s, ivec2 offset) {
	vec2 lattice = vec2(st.x * xFreq, st.y * yFreq);
	vec2 baseFloor = floor(lattice);
	ivec2 base = ivec2(baseFloor) + offset;
	vec2 fracL = lattice - baseFloor;

	int seedInt = int(floor(s));
	float seedFrac = fract(s);

	float xCombined = fracL.x + seedFrac;
	int xi = base.x + seedInt + int(floor(xCombined));
	int yi = base.y;

	uint xBits = uint(xi);
	uint yBits = uint(yi);
	uint seedBits = floatBitsToUint(s);
	uint fracBits = floatBitsToUint(seedFrac);

	uvec3 jitter = uvec3(
		(fracBits * 374761393u) ^ 0x9E3779B9u,
		(fracBits * 668265263u) ^ 0x7F4A7C15u,
		(fracBits * 2246822519u) ^ 0x94D049B4u
	);

	uvec3 state = uvec3(xBits, yBits, seedBits) ^ jitter;
	uvec3 prngState = pcg(state);
	float denom = float(0xffffffffu);
	return vec3(
		float(prngState.x) / denom,
		float(prngState.y) / denom,
		float(prngState.z) / denom
	);
}

// `constant` in the WGSL/GLSL — renamed (MSL reserved keyword).
float constantValue(vec2 st, float xFreq, float yFreq, float s) {
	vec3 randTime = randomFromLatticeWithOffset(st, xFreq, yFreq, s, ivec2(40, 0));
	float scaledTime = periodicFunction(randTime.x - time) * map(abs(speed), 0.0, 100.0, 0.0, 0.333);

	vec3 randv = randomFromLatticeWithOffset(st, xFreq, yFreq, s, ivec2(0, 0));
	return periodicFunction(randv.x - scaledTime);
}

float value(vec2 st, float xFreq, float yFreq, float s) {
	float x1y1 = constantValue(st, xFreq, yFreq, s);

	if (INTERP == 0) {
		return x1y1;
	}

	float ndX = 1.0 / xFreq;
	float ndY = 1.0 / yFreq;

	float x1y2 = constantValue(vec2(st.x, st.y + ndY), xFreq, yFreq, s);
	float x2y1 = constantValue(vec2(st.x + ndX, st.y), xFreq, yFreq, s);
	float x2y2 = constantValue(vec2(st.x + ndX, st.y + ndY), xFreq, yFreq, s);

	vec2 uv = vec2(st.x * xFreq, st.y * yFreq);

	float a = mix(x1y1, x2y1, fract(uv.x));
	float b = mix(x1y2, x2y2, fract(uv.x));

	return mix(a, b, fract(uv.y));
}

const uint BIT_COUNT = 8u;
const int mask = int((1u << BIT_COUNT) - 1u);

int modi(int x, int y) {
	return (x % y) & mask;
}

int or_i(int a, int b) {
	return (a & mask) | (b & mask);
}

int and_i(int a, int b) {
	return (a & mask) & (b & mask);
}

int not_i(int a) {
	return (~a) & mask;
}

int xor_i(int a, int b) {
	return (a & mask) ^ (b & mask);
}

float or_f(float a, float b) {
	return float(or_i(int(a), int(b)));
}

float and_f(float a, float b) {
	return float(and_i(int(a), int(b)));
}

float not_f(float a) {
	return float(not_i(int(a)));
}

float xor_f(float a, float b) {
	return float(xor_i(int(a), int(b)));
}

float mod_f(float a, float b) {
	return a - b * floor(a / b);
}

float bitValue(vec2 st, float freq, float nForColor) {
	float blendy = nForColor + periodicFunction(value(st, freq * 0.01, freq * 0.01, nForColor) * 0.1) * 100.0;

	float v = 1.0;

	if (FORMULA == 0) {
		v = mod_f(xor_f(st.x * freq, st.y * freq), blendy);
	} else if (FORMULA == 1) {
		v = mod_f(or_f(st.x * freq, st.y * freq), blendy);
	} else if (FORMULA == 2) {
		v = mod_f((st.x * freq) * (st.y * freq), blendy);
	} else if (FORMULA == 3) {
		v = (xor_f(st.x * freq, st.y * freq) < blendy) ? 1.0 : 0.0;
	} else if (FORMULA == 4) {
		v = mod_f(st.x * freq * blendy, st.y * freq);
	} else if (FORMULA == 5) {
		v = mod_f(((st.x * freq - 0.5) * 0.25), st.y * freq - 0.5);
	}

	return (v > 1.0) ? 0.0 : 1.0;
}

vec3 bitField(vec2 st) {
	vec2 st2 = st / scale;
	st2 = rotate2D(st2, rotation);

	float freq = map(scale, 1.0, 100.0, scale, 8.0);

	vec3 color = vec3(0.0);

	if (COLOR_SCHEME == 0) {
		color.z = bitValue(st2, freq, n);
	} else if (COLOR_SCHEME == 1) {
		float v1 = bitValue(st2, freq, n);
		color.y = v1;
		color.z = v1;
	} else if (COLOR_SCHEME == 2) {
		color.y = bitValue(st2, freq, n);
	} else if (COLOR_SCHEME == 3) {
		float v2 = bitValue(st2, freq, n);
		color.x = v2;
		color.z = v2;
	} else if (COLOR_SCHEME == 4) {
		color.x = bitValue(st2, freq, n);
	} else if (COLOR_SCHEME == 5) {
		color = vec3(bitValue(st2, freq, n));
	} else if (COLOR_SCHEME == 6) {
		float v3 = bitValue(st2, freq, n);
		color.x = v3;
		color.y = v3;
	} else if (COLOR_SCHEME == 10) {
		color.z = bitValue(st2, freq, n);
		color.y = bitValue(st2, freq, n + 1.0);
	} else if (COLOR_SCHEME == 11) {
		color.z = bitValue(st2, freq, n);
		color.x = bitValue(st2, freq, n + 1.0);
	} else if (COLOR_SCHEME == 12) {
		color.z = bitValue(st2, freq, n);
		float v4 = bitValue(st2, freq, n + 1.0);
		color.x = v4;
		color.y = v4;
	} else if (COLOR_SCHEME == 13) {
		color.y = bitValue(st2, freq, n);
		float v5 = bitValue(st2, freq, n + 1.0);
		color.x = v5;
		color.z = v5;
	} else if (COLOR_SCHEME == 14) {
		color.y = bitValue(st2, freq, n);
		color.x = bitValue(st2, freq, n + 1.0);
	} else if (COLOR_SCHEME == 15) {
		color.x = bitValue(st2, freq, n);
		float v6 = bitValue(st2, freq, n + 1.0);
		color.z = v6;
		color.y = v6;
	} else if (COLOR_SCHEME == 20) {
		color.x = bitValue(st2, freq, n);
		color.y = bitValue(st2, freq, n + 1.0);
		color.z = bitValue(st2, freq, n + 2.0);
	}

	return color;
}

vec3 hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float x = c * (1.0 - abs(mod_f(h * 6.0, 2.0) - 1.0));
	float m = v - c;

	vec3 rgb = vec3(0.0);

	if (0.0 <= h && h < 1.0/6.0) {
		rgb = vec3(c, x, 0.0);
	} else if (1.0/6.0 <= h && h < 2.0/6.0) {
		rgb = vec3(x, c, 0.0);
	} else if (2.0/6.0 <= h && h < 3.0/6.0) {
		rgb = vec3(0.0, c, x);
	} else if (3.0/6.0 <= h && h < 4.0/6.0) {
		rgb = vec3(0.0, x, c);
	} else if (4.0/6.0 <= h && h < 5.0/6.0) {
		rgb = vec3(x, 0.0, c);
	} else if (5.0/6.0 <= h && h < 1.0) {
		rgb = vec3(c, 0.0, x);
	} else {
		rgb = vec3(0.0);
	}

	return rgb + vec3(m, m, m);
}

vec3 rgb2hsv(vec3 rgb) {
	float r = rgb.r;
	float g = rgb.g;
	float b = rgb.b;

	float maxc = max(r, max(g, b));
	float minc = min(r, min(g, b));
	float delta = maxc - minc;

	float h = 0.0;
	if (delta != 0.0) {
		if (maxc == r) {
			h = mod_f((g - b) / delta, 6.0) / 6.0;
		} else if (maxc == g) {
			h = ((b - r) / delta + 2.0) / 6.0;
		} else if (maxc == b) {
			h = ((r - g) / delta + 4.0) / 6.0;
		}
	}

	float s = (maxc != 0.0) ? delta / maxc : 0.0;
	float v = maxc;

	return vec3(h, s, v);
}

float maskValueXY(vec2 st, float xFreq, float yFreq, float s) {
	return constantValue(st, xFreq, yFreq, s);
}

float maskValue(vec2 st, float freq, float s) {
	return maskValueXY(st, freq, freq, s);
}

float arecibo(vec2 st, float xFreq, float yFreq, int _seed) {
	float xMod = mod_f(floor(st.x * xFreq), xFreq);
	float yMod = mod_f(floor(st.y * yFreq), yFreq);

	float v = 1.0;

	if (xMod == 0.0 || yMod == 0.0 || xMod == (xFreq - 1.0) || yMod == (yFreq - 1.0)) {
		v = 0.0;
	} else if (yMod == 1.0) {
		v = (xMod == 1.0) ? 1.0 : 0.0;
	} else {
		v = maskValueXY(st, xFreq, yFreq, float(_seed));
	}

	return v;
}

float areciboNum(vec2 st, float freq, int _seed) {
	return arecibo(st, floor(freq * 0.5) + 1.0, floor(freq), _seed);
}

float glyphs(vec2 st, float freq, int _seed) {
	float xFreq = floor(freq * 0.75);

	float xMod = mod_f(floor(st.x * xFreq), xFreq);
	float yMod = mod_f(floor(st.y * freq), freq);

	float v = 1.0;

	if (xMod == 0.0 || yMod == 0.0 || xMod == (xFreq - 1.0) || yMod == (freq - 1.0)) {
		v = 0.0;
	} else {
		v = maskValueXY(st, xFreq, freq, float(_seed));
	}

	return v;
}

float invaders(vec2 st, float freq, int _seed) {
	float xMod = mod_f(floor(st.x * freq), freq);
	float yMod = mod_f(floor(st.y * freq), freq);

	float v = 1.0;

	if (xMod == 0.0 || yMod == 0.0 || xMod == (freq - 1.0) || yMod == (freq - 1.0)) {
		v = 0.0;
	} else if (xMod >= freq * 0.5) {
		v = maskValue(vec2(floor(st.x) + (1.0 - fract(st.x)), st.y), freq, float(_seed));
	} else {
		v = maskValue(st, freq, float(_seed));
	}

	return v;
}

float bitMaskValue(vec2 st, float freq, int _seed) {
	float v = 1.0;

	if (MASK_FORMULA == 10 || MASK_FORMULA == 11) {
		v = invaders(st, freq, _seed);
	} else if (MASK_FORMULA == 20) {
		v = glyphs(st, freq, _seed);
	} else if (MASK_FORMULA == 30) {
		v = areciboNum(st, freq, _seed);
	}

	return v;
}

vec3 bitMask(vec2 st) {
	vec3 color = vec3(0.0);

	vec2 st2 = st;
	float aspectRatio = resolution.x / resolution.y;
	st2 = st2 - vec2(0.5 * aspectRatio, 0.5);
	st2 = st2 * tiles;
	st2 = st2 + vec2(0.5 * aspectRatio, 0.5);

	st2.x = st2.x - 0.5 * aspectRatio;

	if (MASK_FORMULA == 11) {
		st2.y = st2.y * 2.0;
	}

	float freq = floor(map(complexity, 1.0, 100.0, 5.0, 12.0));

	float maskV = (bitMaskValue(st2, freq, -100) > 0.5) ? 1.0 : 0.0;

	if (MASK_COLOR_SCHEME == 0) {
		color = vec3(maskV);
	} else {
		float baseHue = 0.01 + maskValue(st2, 1.0, -100.0) * baseHueRange * 0.01;

		color.x = fract(baseHue + bitMaskValue(st2, freq, 0) * hueRange * 0.01 + (1.0 - (hueRotation / 360.0))) * maskV;

		if (MASK_COLOR_SCHEME == 3) {
			color.y = maskV;
		} else {
			color.y = bitMaskValue(st2, freq, 25) * maskV;
		}

		if (MASK_COLOR_SCHEME == 2 || MASK_COLOR_SCHEME == 3) {
			color.z = maskV;
		} else {
			color.z = bitMaskValue(st2, freq, 50) * maskV;
		}

		color = hsv2rgb(color);
	}
	return color;
}

void main() {
	resolution = data[0].xy;
	time = data[0].z;
	seed = data[0].w;

	// data[1].x was formula → compile-time FORMULA
	// data[1].y was colorScheme → compile-time COLOR_SCHEME
	n = data[1].z;
	// data[1].w was interp → compile-time INTERP

	scale = data[2].x;
	rotation = data[2].y;
	speed = data[2].z;
	// slot 2 component w unused — `mode` is compile-time MODE

	// data[3].x was maskFormula → compile-time MASK_FORMULA
	tiles = data[3].y;
	complexity = data[3].z;
	// data[3].w was maskColorScheme → compile-time MASK_COLOR_SCHEME

	hueRange = data[4].x;
	hueRotation = data[4].y;
	baseHueRange = data[4].z;

	vec4 color = vec4(0.0, 0.0, 0.0, 1.0);
	vec2 tileOffset = data[5].xy;
	vec2 fullResolution = data[5].zw;
	vec2 st = gl_FragCoord.xy + tileOffset;

	if (MODE == 0) {
		color = vec4(bitField(st), color.a);
	} else {
		st = (gl_FragCoord.xy + tileOffset) / fullResolution.y;
		st = st + float(seed) + 1000.0;
		color = vec4(bitMask(st), color.a);
	}

	frag = color;
}

#version 450
// classicNoisedeck/caustic (Caustic) — ported PIXEL-IDENTICALLY from the canonical
// WGSL source wgsl/caustic.wgsl (cross-checked against the HLSL port
// Shaders/Effects/classicNoisedeck/Caustic.hlsl). Dual-noise caustic pattern with
// "reflect" mode blend. Generator (no inputs). Top-left origin (Godot/Vulkan, matches
// WGSL) — NO per-effect Y-flip (runtime applies the single global flip).
//
// NOISE_TYPE is a compile-time #define injected by the runtime from the graph pass's
// `defines` (see caustic.json globals.interp.define). Kept here as a bare identifier;
// never declared/hardcoded.
//
// Helpers are ALL inlined per effect (PORTING-GUIDE rule 2). nm_core is deliberately
// NOT included: this effect's `periodicFunction` uses sin (map(sin(p*TAU),-1,1,0,1)),
// which differs from nm_core's cos form — substituting it would change every pixel.
// pcg/prng/map are inlined too (identical to nm_core but kept local for a literal
// transcription). `constant`→`constantValue` (MSL reserved-word safety, per guide).
//
// Packed uniformLayout: vec4 data[4] (effects/classicNoisedeck/caustic.json).
//   data[0]: resolution.xy, time.z, seed.w
//   data[1]: (.x freed), noiseScale.y, speed.z, wrap.w
//   data[2]: hueRotation.x, hueRange.y, intensity.z, _pad.w
//   data[3]: tileOffset.xy, fullResolution.zw

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[4]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Values referenced by helper functions (set from data[] in main; WGSL private vars).
vec2 resolution;
float time;
int seed;
float noiseScale;
float speed;
int wrap;
float hueRotation;
float hueRange;
float intensity;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

float modulo(float a, float b) {
	return a - b * floor(a / b);
}

float map(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// PCG PRNG
uvec3 pcg(uvec3 v) {
	uvec3 r = v;
	r = r * 1664525u + 1013904223u;

	r.x += r.y * r.z;
	r.y += r.z * r.x;
	r.z += r.x * r.y;

	r = r ^ (r >> uvec3(16u));

	r.x += r.y * r.z;
	r.y += r.z * r.x;
	r.z += r.x * r.y;

	return r;
}

vec3 prng(vec3 p) {
	vec3 q = p;
	q.x = (q.x >= 0.0) ? (q.x * 2.0) : (-q.x * 2.0 + 1.0);
	q.y = (q.y >= 0.0) ? (q.y * 2.0) : (-q.y * 2.0 + 1.0);
	q.z = (q.z >= 0.0) ? (q.z * 2.0) : (-q.z * 2.0 + 1.0);
	return vec3(pcg(uvec3(q))) / float(0xffffffffu);
}

vec3 brightnessContrast(vec3 color) {
	float bright = map(intensity, -100.0, 100.0, -0.4, 0.4);
	float cont = 1.0;
	if (intensity < 0.0) {
		cont = map(intensity, -100.0, 0.0, 0.5, 1.0);
	} else {
		cont = map(intensity, 0.0, 100.0, 1.0, 1.5);
	}

	return (color - 0.5) * cont + 0.5 + bright;
}

vec3 hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float x = c * (1.0 - abs(modulo(h * 6.0, 2.0) - 1.0));
	float m = v - c;

	vec3 rgb;

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
		rgb = vec3(0.0, 0.0, 0.0);
	}

	return rgb + vec3(m, m, m);
}

float periodicFunction(float p) {
	return map(sin(p * TAU), -1.0, 1.0, 0.0, 1.0);
}

// Simplex 2D
vec3 mod289_3(vec3 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec2 mod289_2(vec2 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec3 permute(vec3 x) {
	return mod289_3(((x*34.0)+1.0)*x);
}

float simplexValue(vec2 st, float xFreq, float yFreq, float s, float blend) {
	const vec4 C = vec4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);

	vec2 uv = vec2(st.x * xFreq, st.y * yFreq);
	uv.x += s;

	vec2 i = floor(uv + dot(uv, C.yy) );
	vec2 x0 = uv -   i + dot(i, C.xx);

	vec2 i1;
	i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
	vec2 x1 = x0 - i1 + vec2(C.x, C.x);
	vec2 x2 = x0 - vec2(1.0, 1.0) + vec2(2.0 * C.x, 2.0 * C.x);
	vec2 x12xz = vec2(x1.x, x2.x);
	vec2 x12yw = vec2(x1.y, x2.y);

	i = mod289_2(i);
	vec3 p = permute( permute( i.y + vec3(0.0, i1.y, 1.0 ))
		  + i.x + vec3(0.0, i1.x, 1.0 ));

	vec3 m = max(vec3(0.5) - vec3(dot(x0, x0), dot(x1, x1), dot(x2, x2)), vec3(0.0));
	m = m*m;
	m = m*m;

	vec3 x = 2.0 * fract(p * C.www) - 1.0;
	vec3 h = abs(x) - 0.5;
	vec3 ox = floor(x + 0.5);
	vec3 a0 = x - ox;

	m *= 1.79284291400159 - 0.85373472095314 * ( a0*a0 + h*h );

	vec3 g;
	g.x  = a0.x  * x0.x  + h.x  * x0.y;
	vec2 gyz = a0.yz * x12xz + h.yz * x12yw;
	g.y = gyz.x;
	g.z = gyz.y;

	float v = 130.0 * dot(m, g);

	return periodicFunction(map(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

float sineNoise(vec2 st, float xFreq, float yFreq, float s, float blend) {
	vec2 uv = vec2(st.x * xFreq, st.y * yFreq);
	uv.x += s;

	float a = blend;
	float b = blend;
	float c = 1.0 - blend;

	vec3 r1 = prng(vec3(s, 0.0, 0.0)) * 0.75 + 0.125;
	vec3 r2 = prng(vec3(s + 10.0, 0.0, 0.0)) * 0.75 + 0.125;
	float x = sin(r1.x * uv.y + sin(r1.y * uv.x + a) + sin(r1.z * uv.x + b) + c);
	float y = sin(r2.x * uv.x + sin(r2.y * uv.y + b) + sin(r2.z * uv.y + c) + a);

	return (x + y) * 0.5 + 0.5;
}

// Value noise
int positiveModulo(int value, int modulus) {
	if (modulus == 0) {
		return 0;
	}

	int r = value % modulus;
	if (r < 0) {
		r += modulus;
	}
	return r;
}

vec3 randomFromLatticeWithOffset(vec2 st, float xFreq, float yFreq, float s, ivec2 offset) {
	vec2 lattice = vec2(st.x * xFreq, st.y * yFreq);
	vec2 baseFloor = floor(lattice);
	ivec2 base = ivec2(int(baseFloor.x), int(baseFloor.y)) + offset;
	vec2 frac = lattice - baseFloor;

	int seedInt = int(floor(s));
	float seedFrac = fract(s);

	int xi = base.x + seedInt + int(floor(frac.x + seedFrac));
	int yi = base.y;

	if (wrap > 0) {
		int freqXInt = int(xFreq + 0.5);
		int freqYInt = int(yFreq + 0.5);

		if (freqXInt > 0) {
			xi = positiveModulo(xi, freqXInt);
		}
		if (freqYInt > 0) {
			yi = positiveModulo(yi, freqYInt);
		}
	}

	uint xBits = uint(xi);
	uint yBits = uint(yi);
	uint seedBits = uint(seed);
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

float constantValue(vec2 st, float xFreq, float yFreq, float s) {
	vec3 rand = randomFromLatticeWithOffset(st, xFreq, yFreq, s, ivec2(0, 0));
	float scaledTime = periodicFunction(rand.x - time) * map(abs(speed), 0.0, 100.0, 0.0, 0.25);
	return periodicFunction(rand.y - scaledTime);
}

float constantOffset(vec2 st, float xFreq, float yFreq, float s, ivec2 offset) {
	vec3 rand = randomFromLatticeWithOffset(st, xFreq, yFreq, s, offset);
	float scaledTime = periodicFunction(rand.x - time) * map(abs(speed), 0.0, 100.0, 0.0, 0.25);
	return periodicFunction(rand.y - scaledTime);
}

float quadratic3(float p0, float p1, float p2, float t) {
	float t2 = t * t;
	return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
	       p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
	       p2 * 0.5 * t2;
}

float catmullRom3(float p0, float p1, float p2, float t) {
	float t2 = t * t;
	float t3 = t2 * t;

	return p1 + 0.5 * t * (p2 - p0) +
	       0.5 * t2 * (2.0*p0 - 5.0*p1 + 4.0*p2 - p0) +
	       0.5 * t3 * (-p0 + 3.0*p1 - 3.0*p2 + p0);
}

float quadratic3x3Value(vec2 st, float xFreq, float yFreq, float s) {
	vec2 lattice = vec2(st.x * xFreq, st.y * yFreq);
	vec2 f = fract(lattice);

	float v00 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, -1));
	float v10 = constantOffset(st, xFreq, yFreq, s, ivec2(0, -1));
	float v20 = constantOffset(st, xFreq, yFreq, s, ivec2(1, -1));

	float v01 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, 0));
	float v11 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 0));
	float v21 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 0));

	float v02 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, 1));
	float v12 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 1));
	float v22 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 1));

	float y0 = quadratic3(v00, v10, v20, f.x);
	float y1 = quadratic3(v01, v11, v21, f.x);
	float y2 = quadratic3(v02, v12, v22, f.x);

	return quadratic3(y0, y1, y2, f.y);
}

float catmullRom3x3Value(vec2 st, float xFreq, float yFreq, float s) {
	vec2 lattice = vec2(st.x * xFreq, st.y * yFreq);
	vec2 f = fract(lattice);

	float v00 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, -1));
	float v10 = constantOffset(st, xFreq, yFreq, s, ivec2(0, -1));
	float v20 = constantOffset(st, xFreq, yFreq, s, ivec2(1, -1));

	float v01 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, 0));
	float v11 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 0));
	float v21 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 0));

	float v02 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, 1));
	float v12 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 1));
	float v22 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 1));

	float y0 = catmullRom3(v00, v10, v20, f.x);
	float y1 = catmullRom3(v01, v11, v21, f.x);
	float y2 = catmullRom3(v02, v12, v22, f.x);

	return catmullRom3(y0, y1, y2, f.y);
}

float blendBicubic(float p0, float p1, float p2, float p3, float t) {
	float t2 = t * t;
	float t3 = t2 * t;

	float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
	float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
	float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
	float b3 = t3 / 6.0;

	return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

float catmullRom4(float p0, float p1, float p2, float p3, float t) {
	return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 +
	       t * (3.0 * (p1 - p2) + p3 - p0)));
}

float blendLinearOrCosine(float a, float b, float amount, int nType) {
	if (nType == 1) {
		return mix(a, b, amount);
	}
	return mix(a, b, smoothstep(0.0, 1.0, amount));
}

float bicubicValue(vec2 st, float xFreq, float yFreq, float s) {
	float x0y0 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, -1));
	float x0y1 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, 0));
	float x0y2 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, 1));
	float x0y3 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, 2));

	float x1y0 = constantOffset(st, xFreq, yFreq, s, ivec2(0, -1));
	float x1y1 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 0));
	float x1y2 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 1));
	float x1y3 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 2));

	float x2y0 = constantOffset(st, xFreq, yFreq, s, ivec2(1, -1));
	float x2y1 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 0));
	float x2y2 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 1));
	float x2y3 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 2));

	float x3y0 = constantOffset(st, xFreq, yFreq, s, ivec2(2, -1));
	float x3y1 = constantOffset(st, xFreq, yFreq, s, ivec2(2, 0));
	float x3y2 = constantOffset(st, xFreq, yFreq, s, ivec2(2, 1));
	float x3y3 = constantOffset(st, xFreq, yFreq, s, ivec2(2, 2));

	vec2 uv = vec2(st.x * xFreq, st.y * yFreq);

	float y0 = blendBicubic(x0y0, x1y0, x2y0, x3y0, fract(uv.x));
	float y1 = blendBicubic(x0y1, x1y1, x2y1, x3y1, fract(uv.x));
	float y2 = blendBicubic(x0y2, x1y2, x2y2, x3y2, fract(uv.x));
	float y3 = blendBicubic(x0y3, x1y3, x2y3, x3y3, fract(uv.x));

	return clamp(blendBicubic(y0, y1, y2, y3, fract(uv.y)), 0.0, 1.0);
}

float catmullRom4x4Value(vec2 st, float xFreq, float yFreq, float s) {
	float x0y0 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, -1));
	float x0y1 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, 0));
	float x0y2 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, 1));
	float x0y3 = constantOffset(st, xFreq, yFreq, s, ivec2(-1, 2));

	float x1y0 = constantOffset(st, xFreq, yFreq, s, ivec2(0, -1));
	float x1y1 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 0));
	float x1y2 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 1));
	float x1y3 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 2));

	float x2y0 = constantOffset(st, xFreq, yFreq, s, ivec2(1, -1));
	float x2y1 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 0));
	float x2y2 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 1));
	float x2y3 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 2));

	float x3y0 = constantOffset(st, xFreq, yFreq, s, ivec2(2, -1));
	float x3y1 = constantOffset(st, xFreq, yFreq, s, ivec2(2, 0));
	float x3y2 = constantOffset(st, xFreq, yFreq, s, ivec2(2, 1));
	float x3y3 = constantOffset(st, xFreq, yFreq, s, ivec2(2, 2));

	vec2 uv = vec2(st.x * xFreq, st.y * yFreq);

	float y0 = catmullRom4(x0y0, x1y0, x2y0, x3y0, fract(uv.x));
	float y1 = catmullRom4(x0y1, x1y1, x2y1, x3y1, fract(uv.x));
	float y2 = catmullRom4(x0y2, x1y2, x2y2, x3y2, fract(uv.x));
	float y3 = catmullRom4(x0y3, x1y3, x2y3, x3y3, fract(uv.x));

	return clamp(catmullRom4(y0, y1, y2, y3, fract(uv.y)), 0.0, 1.0);
}

float value(vec2 st, float xFreq, float yFreq, float s) {
	if (NOISE_TYPE == 0) {
		return constantValue(st, xFreq, yFreq, s);
	}

	if (NOISE_TYPE == 3) {
		return catmullRom3x3Value(st, xFreq, yFreq, s);
	}

	if (NOISE_TYPE == 4) {
		return catmullRom4x4Value(st, xFreq, yFreq, s);
	}

	if (NOISE_TYPE == 5) {
		return quadratic3x3Value(st, xFreq, yFreq, s);
	}

	if (NOISE_TYPE == 6) {
		return bicubicValue(st, xFreq, yFreq, s);
	}

	if (NOISE_TYPE == 10) {
		float simplexLoopSample = simplexValue(st, xFreq, yFreq, s + 50.0, time) * speed * 0.0025;
		return simplexValue(st, xFreq, yFreq, s, simplexLoopSample);
	}

	if (NOISE_TYPE == 11) {
		float sineLoopSample = sineNoise(st, xFreq, yFreq, s + 50.0, time) * speed * 0.0025;
		return sineNoise(st, xFreq, yFreq, s, sineLoopSample);
	}

	// 1 = linear, 2 = hermite
	float x1y1 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 0));
	float x1y2 = constantOffset(st, xFreq, yFreq, s, ivec2(0, 1));
	float x2y1 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 0));
	float x2y2 = constantOffset(st, xFreq, yFreq, s, ivec2(1, 1));

	vec2 uv = vec2(st.x * xFreq, st.y * yFreq);

	float a = blendLinearOrCosine(x1y1, x2y1, fract(uv.x), NOISE_TYPE);
	float b = blendLinearOrCosine(x1y2, x2y2, fract(uv.x), NOISE_TYPE);

	return clamp(blendLinearOrCosine(a, b, fract(uv.y), NOISE_TYPE), 0.0, 1.0);
}

vec3 noise(vec2 st, float s) {
	float freq = 1.0;
	if (NOISE_TYPE != 10 && wrap > 0) {
		freq = floor(map(noiseScale, 1.0, 100.0, 6.0, 2.0));
	} else {
		if (NOISE_TYPE == 10) {
			freq = map(noiseScale, 1.0, 100.0, 1.0, 0.5);
		} else {
			freq = map(noiseScale, 1.0, 100.0, 6.0, 1.0);
		}
	}

	vec3 color = vec3(
		value(st, freq, freq, 0.0 + s),
		value(st, freq, freq, 10.0 + s),
		value(st, freq, freq, 20.0 + s));

	// hue
	color.r = color.r * hueRange * 0.01;
	color.r += 1.0 - (hueRotation / 360.0);

	// saturation
	color.g *= 0.333;

	// brightness - ridges
	color.b = 1.0 - abs(color.b * 2.0 - 1.0);

	color = hsv2rgb(color);

	return color;
}

void main() {
	resolution = data[0].xy;
	time = data[0].z;
	seed = int(data[0].w);
	noiseScale = data[1].y;
	speed = data[1].z;
	wrap = int(data[1].w);
	hueRotation = data[2].x;
	hueRange = data[2].y;
	intensity = data[2].z;
	vec2 tileOffset = data[3].xy;
	vec2 fullResolution = data[3].zw;

	vec2 st = (gl_FragCoord.xy + tileOffset) / fullResolution.y;
	st -= vec2(fullResolution.x / fullResolution.y * 0.5, 0.5);

	vec3 leftColor = noise(st, float(seed));
	vec3 rightColor = noise(st, float(seed) + 10.0);

	// "reflect" mode blend from coalesce
	vec3 left = min(leftColor * rightColor / (1.0 - rightColor * leftColor), vec3(1.0));
	vec3 right = min(rightColor * leftColor / (1.0 - leftColor * rightColor), vec3(1.0));

	frag = vec4(brightnessContrast(mix(left, right, 0.5)), 1.0);
}

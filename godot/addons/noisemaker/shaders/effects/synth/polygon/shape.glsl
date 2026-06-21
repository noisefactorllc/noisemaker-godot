#version 450
// synth/shape — ported from wgsl/shape.wgsl (top-left origin = Godot/Vulkan,
// no Y-flip). Interference patterns from geometric shapes; grayscale output.
// Packed uniformLayout: vec4 data[3] (effects/synth/shape.json).
//
// IMPORTANT (PORTING-GUIDE rule 2): shape's periodicFunction uses sin(), which
// DIFFERS from nm_core's periodicFunction (cos form). It is therefore inlined
// here as shapePeriodicFunction() and the shared one is NOT used.
// pcg/prng/map/PI/TAU come from nm_core. WGSL modulo() == GLSL mod().
//
// LOOP_A_OFFSET / LOOP_B_OFFSET are compile-time consts injected by the runtime
// as `#define` after the #version line (see shape.json globals[*].define). Kept
// as bare identifiers.
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[3]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Values referenced by helper functions (set from data[] in main; WGSL private vars).
vec2 resolution;
float time;
float seed;
bool wrap;
float loopAScale;
float loopBScale;
float speedA;
float speedB;
float aspectRatio;

// periodicFunction(p): SIN form (DIFFERENT from nm_core's cos form).
float shapePeriodicFunction(float p) {
	float x = TAU * p;
	return map(sin(x), -1.0, 1.0, 0.0, 1.0);
}

float constantValue(vec2 st_in, float freq, float speed) {
	float x = st_in.x * freq;
	float y = st_in.y * freq;
	if (wrap) {
		x = mod(x, freq);
		y = mod(y, freq);
	}
	x = x + seed;
	vec3 rand = prng(vec3(floor(vec2(x, y)), seed));
	float scaledTime = shapePeriodicFunction(rand.x - time) * map(abs(speed), 0.0, 100.0, 0.0, 0.33);
	return shapePeriodicFunction(rand.y - scaledTime);
}

// ---- 3x3 quadratic interpolation ----
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

float quadratic3x3Value(vec2 st, float freq, float speed) {
	vec2 lattice = st * freq;
	vec2 f = fract(lattice);
	float nd = 1.0 / freq;

	float v00 = constantValue(st + vec2(-nd, -nd), freq, speed);
	float v10 = constantValue(st + vec2(0.0, -nd), freq, speed);
	float v20 = constantValue(st + vec2(nd, -nd), freq, speed);

	float v01 = constantValue(st + vec2(-nd, 0.0), freq, speed);
	float v11 = constantValue(st, freq, speed);
	float v21 = constantValue(st + vec2(nd, 0.0), freq, speed);

	float v02 = constantValue(st + vec2(-nd, nd), freq, speed);
	float v12 = constantValue(st + vec2(0.0, nd), freq, speed);
	float v22 = constantValue(st + vec2(nd, nd), freq, speed);

	float y0 = quadratic3(v00, v10, v20, f.x);
	float y1 = quadratic3(v01, v11, v21, f.x);
	float y2 = quadratic3(v02, v12, v22, f.x);

	return quadratic3(y0, y1, y2, f.y);
}

float catmullRom3x3Value(vec2 st, float freq, float speed) {
	vec2 lattice = st * freq;
	vec2 f = fract(lattice);
	float nd = 1.0 / freq;

	float v00 = constantValue(st + vec2(-nd, -nd), freq, speed);
	float v10 = constantValue(st + vec2(0.0, -nd), freq, speed);
	float v20 = constantValue(st + vec2(nd, -nd), freq, speed);

	float v01 = constantValue(st + vec2(-nd, 0.0), freq, speed);
	float v11 = constantValue(st, freq, speed);
	float v21 = constantValue(st + vec2(nd, 0.0), freq, speed);

	float v02 = constantValue(st + vec2(-nd, nd), freq, speed);
	float v12 = constantValue(st + vec2(0.0, nd), freq, speed);
	float v22 = constantValue(st + vec2(nd, nd), freq, speed);

	float y0 = catmullRom3(v00, v10, v20, f.x);
	float y1 = catmullRom3(v01, v11, v21, f.x);
	float y2 = catmullRom3(v02, v12, v22, f.x);

	return catmullRom3(y0, y1, y2, f.y);
}

// ---- 4x4 interpolation ----
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

float blendLinearOrCosine(float a, float b, float amount, int interp) {
	if (interp == 1) {
		return mix(a, b, amount);
	}
	return mix(a, b, smoothstep(0.0, 1.0, amount));
}

// Simplex 2D noise helpers
vec3 mod289_v3(vec3 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec2 mod289_v2(vec2 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec3 permute(vec3 x) {
	return mod289_v3(((x * 34.0) + 1.0) * x);
}

float simplexValue(vec2 st, float freq, float s, float blend) {
	vec4 C = vec4(0.211324865405187,
	              0.366025403784439,
	             -0.577350269189626,
	              0.024390243902439);

	vec2 uv = st * freq;
	uv.x = uv.x + s;

	vec2 i = floor(uv + dot(uv, C.yy));
	vec2 x0 = uv - i + dot(i, C.xx);

	vec2 i1;
	if (x0.x > x0.y) {
		i1 = vec2(1.0, 0.0);
	} else {
		i1 = vec2(0.0, 1.0);
	}
	vec4 x12 = x0.xyxy + C.xxzz;
	x12 = vec4(x12.xy - i1, x12.zw);

	vec2 i_mod = mod289_v2(i);
	vec3 p = permute(permute(i_mod.y + vec3(0.0, i1.y, 1.0))
	      + i_mod.x + vec3(0.0, i1.x, 1.0));

	vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), vec3(0.0));
	m = m * m;
	m = m * m;

	vec3 x = 2.0 * fract(p * C.www) - 1.0;
	vec3 h = abs(x) - 0.5;
	vec3 ox = floor(x + 0.5);
	vec3 a0 = x - ox;

	m = m * (1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h));

	vec3 g;
	g.x = a0.x * x0.x + h.x * x0.y;
	g.y = a0.y * x12.x + h.y * x12.y;
	g.z = a0.z * x12.z + h.z * x12.w;

	float v = 130.0 * dot(m, g);

	return shapePeriodicFunction(map(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

float sineNoise(vec2 st_in, float freq, float s, float blend) {
	vec2 st = st_in * freq;
	st.x = st.x + s;

	float a = blend;
	float b = blend;
	float c = 1.0 - blend;

	vec3 r1 = prng(vec3(s, 0.0, 0.0)) * 0.75 + 0.125;
	vec3 r2 = prng(vec3(s + 10.0, 0.0, 0.0)) * 0.75 + 0.125;
	float x = sin(r1.x * st.y + sin(r1.y * st.x + a) + sin(r1.z * st.x + b) + c);
	float y = sin(r2.x * st.x + sin(r2.y * st.y + b) + sin(r2.z * st.y + c) + a);

	return (x + y) * 0.5 + 0.5;
}

float bicubicValue(vec2 st, float freq, float speed) {
	float ndX = 1.0 / freq;
	float ndY = 1.0 / freq;

	float u0 = st.x - ndX;
	float u1 = st.x;
	float u2 = st.x + ndX;
	float u3 = st.x + ndX + ndX;

	float v0 = st.y - ndY;
	float v1 = st.y;
	float v2 = st.y + ndY;
	float v3 = st.y + ndY + ndY;

	float x0y0 = constantValue(vec2(u0, v0), freq, speed);
	float x0y1 = constantValue(vec2(u0, v1), freq, speed);
	float x0y2 = constantValue(vec2(u0, v2), freq, speed);
	float x0y3 = constantValue(vec2(u0, v3), freq, speed);

	float x1y0 = constantValue(vec2(u1, v0), freq, speed);
	float x1y1 = constantValue(st, freq, speed);
	float x1y2 = constantValue(vec2(u1, v2), freq, speed);
	float x1y3 = constantValue(vec2(u1, v3), freq, speed);

	float x2y0 = constantValue(vec2(u2, v0), freq, speed);
	float x2y1 = constantValue(vec2(u2, v1), freq, speed);
	float x2y2 = constantValue(vec2(u2, v2), freq, speed);
	float x2y3 = constantValue(vec2(u2, v3), freq, speed);

	float x3y0 = constantValue(vec2(u3, v0), freq, speed);
	float x3y1 = constantValue(vec2(u3, v1), freq, speed);
	float x3y2 = constantValue(vec2(u3, v2), freq, speed);
	float x3y3 = constantValue(vec2(u3, v3), freq, speed);

	vec2 uv = st * freq;

	float y0 = blendBicubic(x0y0, x1y0, x2y0, x3y0, fract(uv.x));
	float y1 = blendBicubic(x0y1, x1y1, x2y1, x3y1, fract(uv.x));
	float y2 = blendBicubic(x0y2, x1y2, x2y2, x3y2, fract(uv.x));
	float y3 = blendBicubic(x0y3, x1y3, x2y3, x3y3, fract(uv.x));

	return blendBicubic(y0, y1, y2, y3, fract(uv.y));
}

float catmullRom4x4Value(vec2 st, float freq, float speed) {
	float ndX = 1.0 / freq;
	float ndY = 1.0 / freq;

	float u0 = st.x - ndX;
	float u1 = st.x;
	float u2 = st.x + ndX;
	float u3 = st.x + ndX + ndX;

	float v0 = st.y - ndY;
	float v1 = st.y;
	float v2 = st.y + ndY;
	float v3 = st.y + ndY + ndY;

	float x0y0 = constantValue(vec2(u0, v0), freq, speed);
	float x0y1 = constantValue(vec2(u0, v1), freq, speed);
	float x0y2 = constantValue(vec2(u0, v2), freq, speed);
	float x0y3 = constantValue(vec2(u0, v3), freq, speed);

	float x1y0 = constantValue(vec2(u1, v0), freq, speed);
	float x1y1 = constantValue(st, freq, speed);
	float x1y2 = constantValue(vec2(u1, v2), freq, speed);
	float x1y3 = constantValue(vec2(u1, v3), freq, speed);

	float x2y0 = constantValue(vec2(u2, v0), freq, speed);
	float x2y1 = constantValue(vec2(u2, v1), freq, speed);
	float x2y2 = constantValue(vec2(u2, v2), freq, speed);
	float x2y3 = constantValue(vec2(u2, v3), freq, speed);

	float x3y0 = constantValue(vec2(u3, v0), freq, speed);
	float x3y1 = constantValue(vec2(u3, v1), freq, speed);
	float x3y2 = constantValue(vec2(u3, v2), freq, speed);
	float x3y3 = constantValue(vec2(u3, v3), freq, speed);

	vec2 uv = st * freq;

	float y0 = catmullRom4(x0y0, x1y0, x2y0, x3y0, fract(uv.x));
	float y1 = catmullRom4(x0y1, x1y1, x2y1, x3y1, fract(uv.x));
	float y2 = catmullRom4(x0y2, x1y2, x2y2, x3y2, fract(uv.x));
	float y3 = catmullRom4(x0y3, x1y3, x2y3, x3y3, fract(uv.x));

	return catmullRom4(y0, y1, y2, y3, fract(uv.y));
}

float value(vec2 st, float freq, int interp, float speed) {
	if (interp == 3) {
		return catmullRom3x3Value(st, freq, speed);
	} else if (interp == 4) {
		return catmullRom4x4Value(st, freq, speed);
	} else if (interp == 5) {
		return quadratic3x3Value(st, freq, speed);
	} else if (interp == 6) {
		return bicubicValue(st, freq, speed);
	} else if (interp == 10) {
		float scaledTime = shapePeriodicFunction(time) * map(abs(speed), 0.0, 100.0, 0.0, 0.333);
		return simplexValue(st, freq, seed, scaledTime);
	} else if (interp == 11) {
		float scaledTime = shapePeriodicFunction(time) * map(abs(speed), 0.0, 100.0, 0.0, 0.333);
		return sineNoise(st, freq, seed, scaledTime);
	}

	float x1y1 = constantValue(st, freq, speed);

	if (interp == 0) {
		return x1y1;
	}

	float ndX = 1.0 / freq;
	float ndY = 1.0 / freq;

	float x1y2 = constantValue(vec2(st.x, st.y + ndY), freq, speed);
	float x2y1 = constantValue(vec2(st.x + ndX, st.y), freq, speed);
	float x2y2 = constantValue(vec2(st.x + ndX, st.y + ndY), freq, speed);

	vec2 uv = st * freq;

	float a = blendLinearOrCosine(x1y1, x2y1, fract(uv.x), interp);
	float b = blendLinearOrCosine(x1y2, x2y2, fract(uv.x), interp);

	return blendLinearOrCosine(a, b, fract(uv.y), interp);
}

// Shape functions
float circles(vec2 st, float freq) {
	float dist = length(st - vec2(0.5 * aspectRatio, 0.5));
	return dist * freq;
}

float rings(vec2 st, float freq) {
	float dist = length(st - vec2(0.5 * aspectRatio, 0.5));
	return cos(dist * PI * freq);
}

float diamonds(vec4 pos, float freq) {
	vec2 stLocal = pos.xy / resolution.y;
	stLocal = stLocal - vec2(0.5 * aspectRatio, 0.5);
	stLocal = stLocal * freq;
	return (cos(stLocal.x * PI) + cos(stLocal.y * PI));
}

float shape(vec2 st, int sides, float blend) {
	vec2 stLocal = st * 2.0 - vec2(aspectRatio, 1.0);
	float a = atan(stLocal.x, stLocal.y) + PI;
	float r = TAU / float(sides);
	return cos(floor(0.5 + a / r) * r - a) * length(stLocal) * blend;
}

float offset(vec2 st, float freq, int loopOffset, float speed, float seedVal, vec4 pos) {
	if (loopOffset == 10) {
		return circles(st, freq);
	} else if (loopOffset == 20) {
		return shape(st, 3, freq * 0.5);
	} else if (loopOffset == 30) {
		return (abs(st.x - 0.5 * aspectRatio) + abs(st.y - 0.5)) * freq * 0.5;
	} else if (loopOffset >= 40 && loopOffset <= 120) {
		int sides = loopOffset / 10;
		return shape(st, sides, freq * 0.5);
	} else if (loopOffset == 200) {
		return st.x * freq * 0.5;
	} else if (loopOffset == 210) {
		return st.y * freq * 0.5;
	} else if (loopOffset >= 300 && loopOffset <= 380) {
		int idx = (loopOffset - 300) / 10;
		int interp = (idx <= 6) ? idx : idx + 3;
		float f = (loopOffset == 300) ? map(freq, 1.0, 6.0, 1.0, 20.0) : freq;
		return 1.0 - value(st + seedVal, f, interp, speed);
	} else if (loopOffset == 400) {
		return 1.0 - rings(st, freq);
	} else if (loopOffset == 410) {
		return 1.0 - diamonds(pos, freq);
	}
	return 0.0;
}

void main() {
	vec4 pos = gl_FragCoord;

	resolution = data[0].xy;
	time = data[0].z;
	seed = data[0].w;

	wrap = data[1].x > 0.5;
	loopAScale = data[1].w;

	loopBScale = data[2].x;
	speedA = data[2].y;
	speedB = data[2].z;
	// Slot [2].w unused (was paletteMode)

	// Slots [3] and [4] unused (were palette parameters)

	aspectRatio = resolution.x / resolution.y;

	// LOOP_A_OFFSET / LOOP_B_OFFSET are integer selectors injected as #define by
	// the runtime; coerce to int (the value arrives as a float literal, e.g. 40.0).
	int loopAOffset = int(LOOP_A_OFFSET);
	int loopBOffset = int(LOOP_B_OFFSET);

	vec4 color = vec4(0.0, 0.0, 0.0, 1.0);
	vec2 st = pos.xy / resolution.y;

	float lf1 = map(loopAScale, 1.0, 100.0, 6.0, 1.0);
	if (wrap) {
		lf1 = floor(lf1);
		if (loopAOffset >= 200 && loopAOffset < 300) {
			lf1 = lf1 * 2.0;
		}
	}
	float amp1 = map(abs(speedA), 0.0, 100.0, 0.0, 1.0);
	float t1 = 1.0;
	if (speedA < 0.0) {
		t1 = time + offset(st, lf1, loopAOffset, amp1, seed, pos);
	} else if (speedA > 0.0) {
		t1 = time - offset(st, lf1, loopAOffset, amp1, seed, pos);
	}

	float lf2 = map(loopBScale, 1.0, 100.0, 6.0, 1.0);
	if (wrap) {
		lf2 = floor(lf2);
		if (loopBOffset >= 200 && loopBOffset < 300) {
			lf2 = lf2 * 2.0;
		}
	}
	float amp2 = map(abs(speedB), 0.0, 100.0, 0.0, 1.0);
	float t2 = 1.0;
	if (speedB < 0.0) {
		t2 = time + offset(st, lf2, loopBOffset, amp2, seed + 10.0, pos);
	} else if (speedB > 0.0) {
		t2 = time - offset(st, lf2, loopBOffset, amp2, seed + 10.0, pos);
	}

	float a = shapePeriodicFunction(t1) * amp1;
	float b = shapePeriodicFunction(t2) * amp2;

	float d = abs((a + b) - 1.0);

	// Mono output: grayscale intensity
	color = vec4(vec3(d), 1.0);

	frag = color;
}

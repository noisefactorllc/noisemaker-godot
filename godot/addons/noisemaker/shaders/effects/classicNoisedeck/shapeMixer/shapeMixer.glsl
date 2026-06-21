#version 450
// classicNoisedeck/shapeMixer — ported PIXEL-IDENTICALLY from the REFERENCE GLSL
// (glsl/shapeMixer.glsl), which is what the WebGL2 golden runs. Combines two inputs under a
// procedural shape/noise blend (selected by the LOOP_OFFSET compile-time define) then applies
// a cosine palette. Single render pass (progName "shapeMixer").
//
// MULTI-INPUT, no-layout effect (shapeMixer.json has NO uniformLayout). Two inputs in
// pass.inputs order: inputTex = first feed (binding 1), tex = second feed (binding 2). The
// backend SYNTHESIZES the Params UBO + `#define <name> data[slot].comp`; use bare names for
// params (blendMode, loopScale, wrap, seed, animate, paletteMode, paletteOffset, paletteAmp,
// paletteFreq, palettePhase, cyclePalette, rotatePalette, repeatPalette, levels) and engine
// globals (time, fullResolution, tileOffset). LOOP_OFFSET is a compile-time integer #define
// (globals.loopOffset.define) — keep it bare; default loopOffset=10 (circles).
//
// WHY GLSL, NOT WGSL: the canonical wgsl/shapeMixer.wgsl diverges from the GLSL in several
// output-affecting ways, and the golden is the GLSL path. Divergences resolved to GLSL:
//   * randomFromLatticeWithOffset seed handling: GLSL uses seedFrac=0, seedBits=uint(seed)
//     (integer), fracBits=floatBitsToUint(0). The WGSL uses bitcast<u32>(f32(seed)) for
//     seedBits and fract(seed) — a DIFFERENT PRNG state. (Matters for any value-noise mode.)
//   * vec3 blend mode 1 (divide): GLSL `color1 / color2 * factor`; WGSL `color1/(color2*factor)`.
//   * blend modes 7/8 (reflect/refract): GLSL uses the builtins; the WGSL hand-rolls different
//     scalar approximations.
//   * pal() has isNan/isInf guards returning vec3(0.0); the WGSL lacks them.
//   * diamonds() recomputes st from gl_FragCoord (only reached by LOOP_OFFSET==410).
//
// RESERVED-NAME / KEYWORD RENAMES:
//   * The GLSL `#define aspectRatio fullResolution.x/fullResolution.y` collides with the
//     injected engine `#define aspectRatio data[0].w`. Renamed to the local macro SM_AR
//     (same value: fullResolution.x/fullResolution.y).
//   * GLSL helper `constant()` is an MSL keyword (macOS/Metal) -> renamed `constantValue()`.
//   * rgb2hsv locals `max`/`min` (which shadow builtins in the GLSL) -> `maxc`/`minc`.
//   * int/bool params arrive as float UBO components: narrow `int(blendMode)` at call sites,
//     compare `wrap != 0.0`, `int(seed)` where an int is needed.
//
// COORDINATE NOTE: gl_FragCoord top-left, NO Y-flip. st = (gl_FragCoord.xy + tileOffset) /
// fullResolution (the GLSL form; tileOffset=0 / fullResolution==textureSize at parity).
// Inputs sampled at gl_FragCoord.xy / textureSize. textureSample -> texture.
//
// Deliberately does NOT #include nm_core.glsl: this effect's periodicFunction uses sin (not
// nm_core's cos), and it defines its own random/positiveModulo — including the header would
// redefine those symbols. All shared primitives are inlined here (smPcg/smPrng/smMap).

layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

#define SM_PI 3.14159265359
#define SM_TAU 6.28318530718
#define SM_AR (fullResolution.x / fullResolution.y)

// PCG PRNG - MIT License
uvec3 smPcg(uvec3 v) {
	v = v * uint(1664525) + uint(1013904223);
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v ^= v >> uint(16);
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

vec3 smPrng(vec3 p) {
	return vec3(smPcg(uvec3(p))) / float(uint(0xffffffff));
}

vec3 hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float x = c * (1.0 - abs(mod(h * 6.0, 2.0) - 1.0));
	float m = v - c;

	vec3 rgb;

	if (0.0 <= h && h < 1.0 / 6.0) {
		rgb = vec3(c, x, 0.0);
	} else if (1.0 / 6.0 <= h && h < 2.0 / 6.0) {
		rgb = vec3(x, c, 0.0);
	} else if (2.0 / 6.0 <= h && h < 3.0 / 6.0) {
		rgb = vec3(0.0, c, x);
	} else if (3.0 / 6.0 <= h && h < 4.0 / 6.0) {
		rgb = vec3(0.0, x, c);
	} else if (4.0 / 6.0 <= h && h < 5.0 / 6.0) {
		rgb = vec3(x, 0.0, c);
	} else if (5.0 / 6.0 <= h && h < 1.0) {
		rgb = vec3(c, 0.0, x);
	} else {
		rgb = vec3(0.0, 0.0, 0.0);
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
			h = mod((g - b) / delta, 6.0) / 6.0;
		} else if (maxc == g) {
			h = ((b - r) / delta + 2.0) / 6.0;
		} else if (maxc == b) {
			h = ((r - g) / delta + 4.0) / 6.0;
		}
	}

	float s = (maxc == 0.0) ? 0.0 : delta / maxc;
	float v = maxc;

	return vec3(h, s, v);
}

vec3 linearToSrgb(vec3 lin) {
	vec3 srgb;
	for (int i = 0; i < 3; ++i) {
		if (lin[i] <= 0.0031308) {
			srgb[i] = lin[i] * 12.92;
		} else {
			srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055;
		}
	}
	return srgb;
}

// oklab transform and inverse - Public Domain/MIT License
const mat3 fwdA = mat3(1.0, 1.0, 1.0,
					   0.3963377774, -0.1055613458, -0.0894841775,
					   0.2158037573, -0.0638541728, -1.2914855480);

const mat3 fwdB = mat3(4.0767245293, -1.2681437731, -0.0041119885,
					   -3.3072168827, 2.6093323231, -0.7034763098,
					   0.2307590544, -0.3411344290, 1.7068625689);

const mat3 invB = mat3(0.4121656120, 0.2118591070, 0.0883097947,
					   0.5362752080, 0.6807189584, 0.2818474174,
					   0.0514575653, 0.1074065790, 0.6302613616);

const mat3 invA = mat3(0.2104542553, 1.9779984951, 0.0259040371,
					   0.7936177850, -2.4285922050, 0.7827717662,
					   -0.0040720468, 0.4505937099, -0.8086757660);

vec3 oklab_from_linear_srgb(vec3 c) {
	vec3 lms = invB * c;
	return invA * (sign(lms) * pow(abs(lms), vec3(0.3333333333333)));
}

vec3 linear_srgb_from_oklab(vec3 c) {
	vec3 lms = fwdA * c;
	return fwdB * (lms * lms * lms);
}

float posterize(float d, float lev) {
	if (lev == 0.0) {
		return d;
	} else if (lev == 1.0) {
		lev = 2.0;
	}

	d = clamp(d, 0.0, 0.99);
	d *= lev;
	d = floor(d) + 0.5;
	d = d / lev;
	return d;
}

float posterize2(float d, float lev) {
	if (lev == 0.0) {
		return d;
	} else {
		lev += 0.1;
	}

	return floor(d * lev) / lev;
}

vec3 posterize2(vec3 c, float lev) {
	c.r = posterize2(c.r, lev);
	c.g = posterize2(c.g, lev);
	c.b = posterize2(c.b, lev);
	return c;
}

bool isNan(float val) {
	return (val <= 0.0 || 0.0 <= val) ? false : true;
}

bool isInf(float val) {
	return (val != 0.0 && val * 2.0 == val) ? true : false;
}

vec3 pal(float t) {
	if (isNan(t)) {
		return vec3(0.0);
	} else if (isInf(t)) {
		return vec3(0.0);
	}

	vec3 a = paletteOffset;
	vec3 b = paletteAmp;
	vec3 c = paletteFreq;
	vec3 d = palettePhase;

	t = t * repeatPalette + rotatePalette * 0.01;

	vec3 color = a + b * cos(6.28318 * (c * t + d));

	// convert to rgb if palette is in hsv or oklab mode (1=hsv, 2=oklab, 3=rgb)
	if (paletteMode == 1) {
		color = hsv2rgb(color);
	} else if (paletteMode == 2) {
		color.g = color.g * -.509 + .276;
		color.b = color.b * -.509 + .198;
		color = linear_srgb_from_oklab(color);
		color = linearToSrgb(color);
	}

	return color;
}

float luminance(vec3 color) {
	return rgb2hsv(color).b;
}

float smMap(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float rings(vec2 st, float freq) {
	float dist = length(st - vec2(0.5 * SM_AR, 0.5));
	return cos(dist * SM_PI * freq);
}

float circles(vec2 st, float freq) {
	float dist = length(st - vec2(0.5 * SM_AR, 0.5));
	return dist * freq;
}

float diamonds(vec2 st, float freq) {
	st = (gl_FragCoord.xy + tileOffset) / fullResolution.y;
	st -= vec2(0.5 * SM_AR, 0.5);
	st *= freq;
	return (cos(st.x * SM_PI) + cos(st.y * SM_PI));
}

float shape(vec2 st, int sides, float blend) {
	st = st * 2.0 - vec2(SM_AR, 1.0);
	float a = atan(st.x, st.y) + SM_PI;
	float r = SM_TAU / float(sides);
	return cos(floor(0.5 + a / r) * r - a) * length(st) * blend;
}

float random(vec2 st) {
	return smPrng(vec3(st, 0.0)).x;
}

float f(vec2 st) {
	return random(floor(st));
}

float periodicFunction(float p) {
	return smMap(sin(p * SM_TAU), -1.0, 1.0, 0.0, 1.0);
}

// Simplex 2D - MIT License (Ashima Arts)
vec3 mod289(vec3 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec2 mod289(vec2 x) {
	return x - floor(x * (1.0 / 289.0)) * 289.0;
}

vec3 permute(vec3 x) {
	return mod289(((x * 34.0) + 1.0) * x);
}

float simplexValue(vec2 st, float freq, float s, float blend) {
	const vec4 C = vec4(0.211324865405187, 0.366025403784439,
						-0.577350269189626, 0.024390243902439);

	vec2 uv = st * freq;
	st.x *= SM_AR;
	uv.x += s;

	// First corner
	vec2 i = floor(uv + dot(uv, C.yy));
	vec2 x0 = uv - i + dot(i, C.xx);

	// Other corners
	vec2 i1;
	i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
	vec4 x12 = x0.xyxy + C.xxzz;
	x12.xy -= i1;

	// Permutations
	i = mod289(i);
	vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0))
			+ i.x + vec3(0.0, i1.x, 1.0));

	vec3 m = max(0.5 - vec3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
	m = m * m;
	m = m * m;

	vec3 x = 2.0 * fract(p * C.www) - 1.0;
	vec3 h = abs(x) - 0.5;
	vec3 ox = floor(x + 0.5);
	vec3 a0 = x - ox;

	m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);

	vec3 g;
	g.x = a0.x * x0.x + h.x * x0.y;
	g.yz = a0.yz * x12.xz + h.yz * x12.yw;

	float v = 130.0 * dot(m, g);

	return periodicFunction(smMap(v, -1.0, 1.0, 0.0, 1.0) - blend);
}

// Noisemaker value noise - MIT License
int positiveModulo(int value, int modulus) {
	if (modulus == 0) {
		return 0;
	}

	int r = value % modulus;
	return (r < 0) ? r + modulus : r;
}

vec3 randomFromLatticeWithOffset(vec2 st, float freq, ivec2 offsetArg) {
	vec2 lattice = st * freq;
	vec2 baseFloor = floor(lattice);
	ivec2 base = ivec2(baseFloor) + offsetArg;
	vec2 frac = lattice - baseFloor;

	int seedInt = int(seed);
	float seedFrac = 0.0;

	float xCombined = frac.x + seedFrac;
	int xi = base.x + seedInt + int(floor(xCombined));
	int yi = base.y;

	if (wrap != 0.0) {
		int freqInt = int(freq + 0.5);

		if (freqInt > 0) {
			xi = positiveModulo(xi, freqInt);
			yi = positiveModulo(yi, freqInt);
		}
	}

	uint xBits = uint(xi);
	uint yBits = uint(yi);
	uint seedBits = uint(seedInt);
	uint fracBits = floatBitsToUint(seedFrac);

	uvec3 jitter = uvec3(
		(fracBits * 374761393u) ^ 0x9E3779B9u,
		(fracBits * 668265263u) ^ 0x7F4A7C15u,
		(fracBits * 2246822519u) ^ 0x94D049B4u
	);

	uvec3 state = uvec3(xBits, yBits, seedBits) ^ jitter;
	uvec3 prngState = smPcg(state);
	float denom = float(0xffffffffu);
	return vec3(
		float(prngState.x) / denom,
		float(prngState.y) / denom,
		float(prngState.z) / denom
	);
}

float constantValue(vec2 st, float freq) {
	vec3 randTime = randomFromLatticeWithOffset(st, freq, ivec2(40, 0));

	float scaledTime = 1.0;
	if (animate == -1.0) {
		scaledTime = periodicFunction(randTime.x - time);
	} else if (animate == 1.0) {
		scaledTime = periodicFunction(randTime.x + time);
	}

	vec3 rand = randomFromLatticeWithOffset(st, freq, ivec2(0, 0));
	return periodicFunction(rand.x - scaledTime);
}

// 3x3 quadratic B-spline interpolation
float quadratic3(float p0, float p1, float p2, float t) {
	float t2 = t * t;

	float B0 = 0.5 * (1.0 - t) * (1.0 - t);
	float B1 = 0.5 * (-2.0 * t2 + 2.0 * t + 1.0);
	float B2 = 0.5 * t2;

	return p0 * B0 + p1 * B1 + p2 * B2;
}

float quadratic3x3Value(vec2 st, float freq) {
	vec2 lattice = st * freq;
	vec2 f = fract(lattice);

	float nd = 1.0 / freq;

	float v00 = constantValue(st + vec2(-nd, -nd), freq);
	float v10 = constantValue(st + vec2(0.0, -nd), freq);
	float v20 = constantValue(st + vec2(nd, -nd), freq);

	float v01 = constantValue(st + vec2(-nd, 0.0), freq);
	float v11 = constantValue(st, freq);
	float v21 = constantValue(st + vec2(nd, 0.0), freq);

	float v02 = constantValue(st + vec2(-nd, nd), freq);
	float v12 = constantValue(st + vec2(0.0, nd), freq);
	float v22 = constantValue(st + vec2(nd, nd), freq);

	float y0 = quadratic3(v00, v10, v20, f.x);
	float y1 = quadratic3(v01, v11, v21, f.x);
	float y2 = quadratic3(v02, v12, v22, f.x);

	return quadratic3(y0, y1, y2, f.y);
}

float blendLinearOrCosine(float a, float b, float amount, int interp) {
	if (interp == 1) {
		return mix(a, b, amount);
	}

	return mix(a, b, smoothstep(0.0, 1.0, amount));
}

float value(vec2 st, float freq, int interp) {
	vec2 st2 = st - vec2(0.5 * SM_AR, 0.5);
	float scaledTime = 1.0;
	float d = 0.0;

	if (interp == 5) {
		d = quadratic3x3Value(st, freq);
	} else if (interp == 10) {
		if (animate == -1.0) {
			scaledTime = simplexValue(st, freq, float(seed) + 40.0, time);
		} else if (animate == 1.0) {
			scaledTime = simplexValue(st, freq, float(seed) + 40.0, -time);
		}
		d = simplexValue(st, freq, float(seed), scaledTime);
	} else {
		float x1y1 = constantValue(st, freq);

		if (interp == 0) {
			d = x1y1;
		} else {
			float ndX = 1.0 / freq;
			float ndY = 1.0 / freq;

			float x1y2 = constantValue(vec2(st.x, st.y + ndY), freq);
			float x2y1 = constantValue(vec2(st.x + ndX, st.y), freq);
			float x2y2 = constantValue(vec2(st.x + ndX, st.y + ndY), freq);

			vec2 uv = st * freq;

			float a = blendLinearOrCosine(x1y1, x2y1, fract(uv.x), interp);
			float b = blendLinearOrCosine(x1y2, x2y2, fract(uv.x), interp);

			d = blendLinearOrCosine(a, b, fract(uv.y), interp);
		}
	}
	return d;
}

float sineNoise(vec2 st, float freq) {
	st -= vec2(SM_AR * 0.5, 0.5);
	st *= freq;
	st += vec2(SM_AR * 0.5, 0.5);

	vec3 r1 = smPrng(vec3(float(seed)));
	vec3 r2 = smPrng(vec3(float(seed) + 10.0));

	float scaleA = r1.x * SM_TAU;
	float scaleC = r1.y * SM_TAU;
	float scaleB = r1.z * SM_TAU;
	float scaleD = r2.x * SM_TAU;

	float offA = r2.y * SM_TAU;
	float offB = r2.z * SM_TAU;
	return sin(scaleA * st.x + sin(scaleB * st.y + offA)) + sin(scaleC * st.y + sin(scaleD * st.x + offB)) * 0.5 + 0.5;
}

float offset(vec2 st, float freq) {
	st.x *= SM_AR;

	float d = 0.0;
	if (LOOP_OFFSET == 10) {
		// circle
		d = circles(st, freq);
	} else if (LOOP_OFFSET == 20) {
		d = shape(st, 3, freq * 0.5);
	} else if (LOOP_OFFSET == 30) {
		d = (abs(st.x - 0.5 * SM_AR) + abs(st.y - 0.5)) * freq * 0.5;
	} else if (LOOP_OFFSET >= 40 && LOOP_OFFSET <= 80) {
		int sides = LOOP_OFFSET / 10;
		d = shape(st, sides, freq * 0.5);
	} else if (LOOP_OFFSET == 200) {
		d = st.x * freq * 0.5;
	} else if (LOOP_OFFSET == 210) {
		d = st.y * freq * 0.5;
	} else if (LOOP_OFFSET == 380) {
		return 1.0 - sineNoise(st, freq);
	} else if (LOOP_OFFSET >= 300 && LOOP_OFFSET <= 370) {
		int idx = (LOOP_OFFSET - 300) / 10;
		int interp = idx <= 6 ? idx : idx + 3;
		d = 1.0 - value(st, freq, interp);
	} else if (LOOP_OFFSET == 400) {
		// rings
		d = 1.0 - rings(st, freq);
	} else if (LOOP_OFFSET == 410) {
		// sine
		d = 1.0 - diamonds(st, freq) * 0.5 + 0.5;
	}

	return d;
}

vec3 blend(vec3 color1, vec3 color2, int mode, float factor) {
	vec3 color = vec3(0.0);

	factor = 1.0 - factor;

	if (mode == 0) {
		color = color1 + color2 * factor;
	} else if (mode == 1) {
		color = color1 / color2 * factor;
	} else if (mode == 2) {
		color = max(color1, color2 * factor);
	} else if (mode == 3) {
		color = min(color1, color2 * factor);
	} else if (mode == 4) {
		factor = clamp(factor, 0.0, 1.0);
		color = mix(color1, color2, factor);
	} else if (mode == 5) {
		color = mod(color1, color2 * factor);
	} else if (mode == 6) {
		color = color1 * color2 * factor;
	} else if (mode == 7) {
		color = reflect(color1, color2 * factor);
	} else if (mode == 8) {
		color = refract(color1, color2, factor);
	} else if (mode == 9) {
		color = color1 - color2 * factor;
	} else {
		factor = clamp(factor, 0.0, 1.0);
		color = mix(color1, color2, factor);
	}

	return color;
}

float blend(float color1, float color2, int mode, float factor) {
	float color = 0.0;

	factor = 1.0 - factor;

	if (mode == 0) {
		color = color1 + color2 * factor;
	} else if (mode == 1) {
		color2 = max(0.1, color2 * factor);
		color = color1 / color2;
	} else if (mode == 2) {
		color = max(color1, color2 * factor);
	} else if (mode == 3) {
		color = min(color1, color2 * factor);
	} else if (mode == 4) {
		factor = clamp(factor, 0.0, 1.0);
		color = mix(color1, color2, factor);
	} else if (mode == 5) {
		color2 = max(0.1, color2 * factor);
		color = mod(color1, color2);
	} else if (mode == 6) {
		color = color1 * color2 * factor;
	} else if (mode == 7) {
		color = reflect(color1, color2 * factor);
	} else if (mode == 8) {
		color = refract(color1, color2, factor);
	} else if (mode == 9) {
		color = color1 - color2 * factor;
	} else {
		factor = clamp(factor, 0.0, 1.0);
		color = mix(color1, color2, factor);
	}

	return color;
}

void main() {
	vec2 globalCoord = gl_FragCoord.xy + tileOffset;
	vec4 color = vec4(0.0, 0.0, 1.0, 1.0);
	vec2 st = globalCoord / fullResolution;

	vec4 color1 = texture(inputTex, gl_FragCoord.xy / vec2(textureSize(inputTex, 0)));
	vec4 color2 = texture(tex, gl_FragCoord.xy / vec2(textureSize(tex, 0)));

	float freq = 1.0;
	if (LOOP_OFFSET == 350) {
		freq = smMap(loopScale, 1.0, 100.0, 12.0, 0.5);
	} else {
		freq = smMap(loopScale, 1.0, 100.0, 10.0, 2.0);
	}
	if (LOOP_OFFSET >= 300 && LOOP_OFFSET < 340 && wrap != 0.0) {
		freq = floor(freq);  // for seamless noise
		freq *= 2.0;
	}

	float t = 1.0;
	if (animate == -1.0) {
		t = time + offset(st, freq);
	} else if (animate == 1.0) {
		t = time - offset(st, freq);
	} else {
		t = offset(st, freq);
	}
	float blendy = periodicFunction(t);

	if (LOOP_OFFSET == 0) {
		blendy = 0.5;
	}

	// avg color of 1 and 2 and blend with float version of blend, then apply palette
	float avg1 = luminance(color1.rgb);
	float avg2 = luminance(color2.rgb);
	float avgMix = blend(avg1, avg2, int(blendMode), blendy);
	float d = posterize(avgMix, levels);

	if (paletteMode == 4) {
		color.rgb = blend(color1.rgb, color2.rgb, int(blendMode), blendy * 0.5);

		color.rgb = rgb2hsv(color.rgb);
		color.r += rotatePalette * 0.01;

		if (cyclePalette == -1) {
			color.r = mod(color.r + time, 1.0);
		} else if (cyclePalette == 1) {
			color.r = mod(color.r - time, 1.0);
		}

		color.rgb = hsv2rgb(color.rgb);
		color.rgb = posterize2(color.rgb, levels);
	} else {
		if (cyclePalette == -1) {
			color.rgb = pal(d + time);
		} else if (cyclePalette == 1) {
			color.rgb = pal(d - time);
		} else {
			color.rgb = pal(d);
		}
	}

	color.a = max(color1.a, color2.a);

	frag = color;
}

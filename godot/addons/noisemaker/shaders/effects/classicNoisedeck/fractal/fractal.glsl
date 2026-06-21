#version 450
// classicNoisedeck/fractal — ported PIXEL-IDENTICALLY from the canonical WGSL source
//   shaders/effects/classicNoisedeck/fractal/wgsl/fractal.wgsl
// (cross-checked against noisemaker-hlsl .../Effects/classicNoisedeck/Fractal.hlsl).
//
// Generator (no texture inputs). Single render pass. Layout effect: the effect's
// reference uniformLayout is PRESENT (effects/classicNoisedeck/fractal.json), so this
// shader declares its OWN std140 Params UBO and reads data[] verbatim — the backend
// performs NO #define / header injection (nm_backend.gd: only no-layout effects get
// the synthesized header). Packed vec4 data[11] mirrors the WGSL Uniforms struct:
//   0: resolution.xy, time, (unused)
//   1: fractalType, symmetry, offsetX, offsetY
//   2: centerX, centerY, zoomAmt, speed
//   3: rotation, iterations, mode, colorMode
//   4: paletteMode, cyclePalette, rotatePalette, repeatPalette
//   5: paletteOffset.xyz, hueRange
//   6: paletteAmp.xyz, levels
//   7: paletteFreq.xyz, backgroundOpacity
//   8: palettePhase.xyz, cutoff
//   9: backgroundColor.xyz, (unused)
//  10: tileOffset.xy, fullResolution.zw   (Godot/runtime tail; not in original WGSL)
//
// All helpers (modulo, map, rotate2D, hsv2rgb, linearToSrgb, oklab, pal, fx, fpx,
// divide, newton, julia, mandelbrot) are this effect's OWN versions, inlined VERBATIM
// (PORTING-GUIDE rule 2); none come from nm_core, so nm_core is not included.
//
// Coordinate parity: st = (gl_FragCoord.xy + tileOffset) / fullResolution.y — divide
// by HEIGHT only. gl_FragCoord is top-left (matches WGSL @builtin(position)); the WGSL
// has no Y-flip, so none is added (PORTING-GUIDE golden rule 1).
//
// rotate2D parity note: WGSL `mat2x2<f32>(c, s, -s, c) * st` is column-major
// (col0=(c,s), col1=(-s,c)) → result = (c*x - s*y, s*x + c*y). Transcribed faithfully
// below as `mat2(c, s, -s, c) * st` (GLSL mat2 is column-major identical). Only matters
// for nonzero rotation; the parity program fractal() uses rotation=0.

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[11]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

float modulo(float a, float b) {
	return a - b * floor(a / b);
}

float map(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

vec2 rotate2D(vec2 st0, float rot, float aspect) {
	vec2 st = st0;
	float r = map(rot, 0.0, 360.0, 0.0, 2.0);
	float angle = r * PI;
	st = st - vec2(0.5 * aspect, 0.5);
	float s = sin(angle);
	float c = cos(angle);
	st = mat2(c, s, -s, c) * st;
	st = st + vec2(0.5 * aspect, 0.5);
	return st;
}

vec3 hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;
	float c = v * s;
	float x = c * (1.0 - abs(modulo(h * 6.0, 2.0) - 1.0));
	float m = v - c;
	vec3 rgb = vec3(0.0, 0.0, 0.0);
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
	}
	return rgb + vec3(m, m, m);
}

vec3 linearToSrgb(vec3 linear) {
	vec3 srgb = vec3(0.0, 0.0, 0.0);
	for (int i = 0; i < 3; i = i + 1) {
		if (linear[i] <= 0.0031308) {
			srgb[i] = linear[i] * 12.92;
		} else {
			srgb[i] = 1.055 * pow(linear[i], 1.0 / 2.4) - 0.055;
		}
	}
	return srgb;
}

// oklab transform and inverse - Public Domain/MIT License
// WGSL mat3x3<f32>(col0, col1, col2) → GLSL mat3(col0, col1, col2): both column-major,
// M*v identical. Columns transcribed verbatim from the WGSL constants.
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
// end oklab

vec3 pal(float t0, vec3 paletteOffset, vec3 paletteAmp, vec3 paletteFreq, vec3 palettePhase, int paletteMode) {
	vec3 color = paletteOffset + paletteAmp * cos(TAU * (paletteFreq * t0 + palettePhase));
	vec3 col = color;
	if (paletteMode == 1) {
		col = hsv2rgb(col);
	} else if (paletteMode == 2) {
		col.g = col.g * -0.509 + 0.276;
		col.b = col.b * -0.509 + 0.198;
		col = linear_srgb_from_oklab(col);
		col = linearToSrgb(col);
	}
	return col;
}

vec2 fx(vec2 z) {
	return vec2(pow(z.x, 3.0) - 3.0 * z.x * pow(z.y, 2.0) - 1.0, 3.0 * pow(z.x, 2.0) * z.y - pow(z.y, 3.0));
}

vec2 fpx(vec2 z) {
	return vec2(3.0 * pow(z.x, 2.0) - 3.0 * pow(z.y, 2.0), 6.0 * z.x * z.y);
}

vec2 divide(vec2 z1, vec2 z2) {
	return vec2(
		(z1.x * z2.x + z1.y * z2.y) / (pow(z2.x, 2.0) + pow(z2.y, 2.0)),
		(z1.y * z2.x - z1.x * z2.y) / (pow(z2.x, 2.0) + pow(z2.y, 2.0))
	);
}

float newton(vec2 st0, int maxIter, float offsetX, float offsetY, float speed, float centerX, float centerY, float zoomAmt, float rotation, float time, int mode, float aspect) {
	vec2 st = rotate2D(st0, rotation + 90.0, aspect);
	st = st - vec2(0.5 * aspect, 0.5);
	st = st * map(zoomAmt, 0.0, 130.0, 1.0, 0.01);
	float s = map(speed, 0.0, 100.0, 0.0, 1.0);
	float offX = map(offsetX, -100.0, 100.0, -0.25, 0.25);
	float offY = map(offsetY, -100.0, 100.0, -0.25, 0.25);
	st.x = st.x + centerY * 0.01;
	st.y = st.y + centerX * 0.01;
	vec2 n = st;
	float iterCount = 0.0;
	vec2 tst = vec2(0.0, 0.0);
	for (int i = 0; i < maxIter; i = i + 1) {
		tst = divide(fx(n), fpx(n));
		tst = tst + vec2(sin(time * TAU), cos(time * TAU)) * 0.1 * s;
		tst = tst + vec2(offX, offY);
		if (length(tst) < 0.001) {
			break;
		}
		n = n - tst;
		iterCount = iterCount + 1.0;
	}
	if (mode == 0) {
		if (maxIter == 0) {
			return 0.0;
		}
		return iterCount / float(maxIter);
	} else {
		return length(n);
	}
}

float julia(vec2 st0, float zoomAmt, float speed, float offsetX, float offsetY, float rotation, float centerX, float centerY, int maxIter, float cutoff, float time, int mode, float aspect) {
	float zoom = map(zoomAmt, 0.0, 100.0, 2.0, 0.5);
	float speedy = map(speed, 0.0, 100.0, 0.0, 1.0);
	float s = mix(speedy * 0.05, speedy * 0.125, speedy);
	float _offsetX = map(offsetX, -100.0, 100.0, -0.5, 0.5);
	float _offsetY = map(offsetY, -100.0, 100.0, -1.0, 1.0);
	vec2 c = vec2(sin(time * TAU) * s + _offsetX, cos(time * TAU) * s + _offsetY);
	vec2 st = rotate2D(st0, rotation, aspect);
	st = (st - vec2(0.5 * aspect, 0.5)) * zoom;
	vec2 z = vec2(
		st.x + map(centerX, -100.0, 100.0, 1.0, -1.0),
		st.y + map(centerY, -100.0, 100.0, 1.0, -1.0)
	);
	int iterCount = 0;
	int iterScaled = maxIter * 2;
	for (int i = 0; i < iterScaled; i = i + 1) {
		iterCount = i;
		float x = (z.x * z.x - z.y * z.y) + c.x;
		float y = (z.y * z.x + z.x * z.y) + c.y;
		if ((x * x + y * y) > 4.0) {
			break;
		}
		z.x = x;
		z.y = y;
	}
	if ((iterScaled - iterCount) < int(cutoff)) {
		return 1.0;
	}
	if (mode == 0) {
		if (iterScaled == 0) {
			return 0.0;
		}
		return float(iterCount) / float(iterScaled);
	} else {
		return length(z);
	}
}

float mandelbrot(vec2 st0, float zoomAmt, float speed, float rotation, float centerX, float centerY, int iter, float time, int mode, float aspect) {
	float zoom = map(zoomAmt, 0.0, 100.0, 2.0, 0.5);
	float speedy = map(speed, 0.0, 100.0, 0.0, 1.0);
	float s = mix(speedy * 0.05, speedy * 0.125, speedy);
	vec2 st = rotate2D(st0, rotation, aspect);
	st.y = st.y * 2.0 - 1.0;
	st.x = st.x * 2.0 - aspect;
	vec2 z = vec2(0.0, 0.0);
	vec2 c = zoom * st - vec2(centerX + 50.0, centerY) * 0.01;
	z = z + vec2(sin(time * TAU), cos(time * TAU)) * s;
	float i = 0.0;
	for (i = 0.0; i < float(iter); i = i + 1.0) {
		mat2 m = mat2(z.x, z.y, -z.y, z.x);
		z = m * z + c;
		if (dot(z, z) > 16.0) {
			break;
		}
	}
	if (i == float(iter)) {
		return 1.0;
	}
	if (mode == 0) {
		return i / float(iter);
	} else {
		return length(z) / float(iter);
	}
}

void main() {
	vec2 resolution = data[0].xy;
	float time = data[0].z;
	int fractalType = int(data[1].x);
	int symmetry = int(data[1].y); // unused
	float offsetX = data[1].z;
	float offsetY = data[1].w;
	float centerX = data[2].x;
	float centerY = data[2].y;
	float zoomAmt = data[2].z;
	float speed = data[2].w;
	float rotation = data[3].x;
	int iterations = int(data[3].y);
	int mode = int(data[3].z);
	int colorMode = int(data[3].w);

	int paletteMode = int(data[4].x);
	int cyclePalette = int(data[4].y);
	float rotatePalette = data[4].z;
	float repeatPalette = data[4].w;
	vec3 paletteOffset = data[5].xyz;
	float hueRange = data[5].w;
	vec3 paletteAmp = data[6].xyz;
	float levels = data[6].w;
	vec3 paletteFreq = data[7].xyz;
	float backgroundOpacity = data[7].w;
	vec3 palettePhase = data[8].xyz;
	float cutoff = data[8].w;
	vec3 backgroundColor = data[9].xyz;
	vec2 tileOffset = data[10].xy;
	vec2 fullResolution = data[10].zw;
	float aspect = fullResolution.x / fullResolution.y;

	vec4 color = vec4(0.0, 0.0, 1.0, 1.0);
	vec2 st = (gl_FragCoord.xy + tileOffset) / fullResolution.y;
	float d = 0.0;
	if (fractalType == 0) {
		d = julia(st, zoomAmt, speed, offsetX, offsetY, rotation, centerX, centerY, iterations, cutoff, time, mode, aspect);
	} else if (fractalType == 1) {
		d = newton(st, iterations, offsetX, offsetY, speed, centerX, centerY, zoomAmt, rotation, time, mode, aspect);
	} else {
		d = mandelbrot(st, zoomAmt, speed, rotation, centerX, centerY, iterations, time, mode, aspect);
	}
	if (d == 1.0) {
		color = vec4(backgroundColor, backgroundOpacity * 0.01);
	} else {
		float dd = d;
		if (cyclePalette == -1) {
			dd = dd - time;
		} else if (cyclePalette == 1) {
			dd = dd + time;
		}
		dd = dd * repeatPalette + rotatePalette * 0.01;
		dd = fract(dd);
		if (levels > 0.0) {
			float lev = levels + 1.0;
			dd = floor(dd * lev) / lev;
		}
		if (colorMode == 0) {
			color = vec4(vec3(fract(dd)), color.a);
		} else if (colorMode == 4) {
			color = vec4(pal(dd, paletteOffset, paletteAmp, paletteFreq, palettePhase, paletteMode), color.a);
		} else if (colorMode == 6) {
			float d2 = dd * (hueRange * 0.01);
			color = vec4(hsv2rgb(vec3(d2, 1.0, 1.0)), color.a);
		}
	}
	vec2 st2 = gl_FragCoord.xy / resolution;

	frag = color;
}

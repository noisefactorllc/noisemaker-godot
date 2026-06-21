#version 450
// classicNoisedeck/cellNoise — ported PIXEL-IDENTICALLY from wgsl/cellNoise.wgsl. Worley
// cellular distance field with deterministic per-cell jitter, shaped by a polar/diamond
// metric, optionally colored via a cosine palette (oklab/hsv modes), optionally modulated
// by an input texture. Single render pass (progName "cellNoise").
//
// LAYOUT effect (cellNoise.json has a `uniformLayout`, 9 slots): this shader declares its
// OWN Params UBO and reads `data[slot].comp` exactly as the WGSL `uniforms.data[i]`. The
// backend does NOT synthesize a layout or inject #defines, so the WGSL locals (time, seed,
// scale, speed, ...) are plain locals with NO reserved-name macro collisions.
//   data[0]=(resolution.xy, time, seed)   data[1]=(metric/shape, scale, cellScale, cellSmooth)
//   data[2]=(variation, speed, paletteMode, colorMode)   data[3]=(paletteOffset.xyz, cyclePalette)
//   data[4]=(paletteAmp.xyz, rotatePalette)   data[5]=(paletteFreq.xyz, repeatPalette)
//   data[6]=(palettePhase.xyz, _)   data[7]=(texInfluence, texIntensity, _, _)
//   data[8]=(tileOffset.xy, fullResolution.zw)
//
// Input `tex` (pass.inputs order) at set 0, binding 1 (the WGSL had sampler `samp` at
// binding 1 + texture `tex` at binding 2; Godot uses one combined sampler2D at binding 1).
// As a generator the `tex` surface resolves to the black 1x1 texture (luminosity 0); with
// texIntensity default 0 the texInfluence path is a no-op regardless.
//
// COORDINATE NOTE: ported from WGSL (top-left). st = (gl_FragCoord.xy + tileOffset) /
// fullResolution.y, exactly the WGSL. NO Y-flip. textureSample -> texture. WGSL
// `select(a,b,c)` -> `c ? b : a` (operands reversed). atan2 -> atan. The inner
// `let speed = floor(speed)` (shadowing the cells() param) is renamed `spd` for GLSL.
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[9]; };
layout(set = 0, binding = 1) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float CN_PI = 3.14159265359;
const float CN_TAU = 6.28318530718;

float cnModulo(float a, float b) {
	return a - b * floor(a / b);
}

float cnMap(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// PCG PRNG - MIT License
uvec3 cnPcg(uvec3 seed) {
	uvec3 v = seed * 1664525u + 1013904223u;
	v.x = v.x + v.y * v.z;
	v.y = v.y + v.z * v.x;
	v.z = v.z + v.x * v.y;
	v = v ^ (v >> uvec3(16u));
	v.x = v.x + v.y * v.z;
	v.y = v.y + v.z * v.x;
	v.z = v.z + v.x * v.y;
	return v;
}

vec3 cnPrng(vec3 p0) {
	vec3 p = p0;
	if (p.x >= 0.0) { p.x = p.x * 2.0; } else { p.x = -p.x * 2.0 + 1.0; }
	if (p.y >= 0.0) { p.y = p.y * 2.0; } else { p.y = -p.y * 2.0 + 1.0; }
	if (p.z >= 0.0) { p.z = p.z * 2.0; } else { p.z = -p.z * 2.0 + 1.0; }
	uvec3 u = cnPcg(uvec3(p));
	return vec3(u) / float(0xffffffffu);
}

vec3 cnHsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float x = c * (1.0 - abs(cnModulo(h * 6.0, 2.0) - 1.0));
	float m = v - c;

	vec3 rgb = vec3(0.0);
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

vec3 cnLinearToSrgb(vec3 lin) {
	vec3 srgb = vec3(0.0);
	for (int i = 0; i < 3; i = i + 1) {
		if (lin[i] <= 0.0031308) {
			srgb[i] = lin[i] * 12.92;
		} else {
			srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055;
		}
	}
	return srgb;
}

// oklab transform and inverse - Public Domain/MIT License
const mat3 CN_fwdA = mat3(
	vec3(1.0, 1.0, 1.0),
	vec3(0.3963377774, -0.1055613458, -0.0894841775),
	vec3(0.2158037573, -0.0638541728, -1.2914855480)
);

const mat3 CN_fwdB = mat3(
	vec3(4.0767245293, -1.2681437731, -0.0041119885),
	vec3(-3.3072168827, 2.6093323231, -0.7034763098),
	vec3(0.2307590544, -0.3411344290, 1.7068625689)
);

const mat3 CN_invB = mat3(
	vec3(0.4121656120, 0.2118591070, 0.0883097947),
	vec3(0.5362752080, 0.6807189584, 0.2818474174),
	vec3(0.0514575653, 0.1074065790, 0.6302613616)
);

const mat3 CN_invA = mat3(
	vec3(0.2104542553, 1.9779984951, 0.0259040371),
	vec3(0.7936177850, -2.4285922050, 0.7827717662),
	vec3(-0.0040720468, 0.4505937099, -0.8086757660)
);

vec3 cnLinearSrgbFromOklab(vec3 c) {
	vec3 lms = CN_fwdA * c;
	return CN_fwdB * (lms * lms * lms);
}

vec3 cnPal(float t0, vec3 paletteOffset, vec3 paletteAmp, vec3 paletteFreq, vec3 palettePhase, int paletteMode, float rotatePalette, float repeatPalette) {
	float t = t0 * repeatPalette + rotatePalette * 0.01;
	vec3 color = paletteOffset + paletteAmp * cos(CN_TAU * (paletteFreq * t + palettePhase));

	if (paletteMode == 1) {
		color = cnHsv2rgb(color);
	} else if (paletteMode == 2) {
		color.g = color.g * -0.509 + 0.276;
		color.b = color.b * -0.509 + 0.198;
		color = cnLinearSrgbFromOklab(color);
		color = cnLinearToSrgb(color);
	}
	return color;
}

float cnLuminance(vec3 color) {
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

float cnPolarShape(vec2 st, int sides) {
	float a = atan(st.x, st.y) + CN_PI;
	float r = CN_TAU / float(sides);
	return cos(floor(0.5 + a / r) * r - a) * length(st);
}

float cnShape(vec2 st0, vec2 offset, int kind, float scale) {
	vec2 st = st0 + offset;
	float d = 1.0;
	if (kind == 0) {
		d = length(st * 1.2);
	} else if (kind == 2) {
		d = cnPolarShape(st * 1.2, 6);
	} else if (kind == 3) {
		d = cnPolarShape(st * 1.2, 8);
	} else if (kind == 4) {
		d = cnPolarShape(st * 1.5, 4);
	} else if (kind == 6) {
		vec2 st2 = st;
		st2.y = st2.y + 0.05;
		d = cnPolarShape(st2 * 1.5, 3);
	}
	return d * scale;
}

float cnSmin(float a, float b, float k) {
	if (k == 0.0) { return min(a, b); }
	float h = max(k - abs(a - b), 0.0) / k;
	return min(a, b) - h * h * k * 0.25;
}

float cnCells(vec2 st0, float freq, float cellSize, int metric, int seed, float speed, float cellVariation, float cellSmooth, float time, float aspect) {
	vec2 st = st0;
	st = st - vec2(0.5 * aspect, 0.5);
	st = st * freq;
	st = st + vec2(0.5 * aspect, 0.5);
	st = st + cnPrng(vec3(float(seed))).xy;

	vec2 i = floor(st);
	vec2 f = fract(st);

	float d = 1.0;
	for (int y = -2; y <= 2; y = y + 1) {
		for (int x = -2; x <= 2; x = x + 1) {
			vec2 n = vec2(float(x), float(y));
			vec2 wrap = i + n;
			vec2 point = cnPrng(vec3(wrap, float(seed))).xy;

			vec3 r1 = cnPrng(vec3(float(seed), wrap)) * 0.5 - vec3(0.25);
			vec3 r2 = cnPrng(vec3(wrap, float(seed))) * 2.0 - vec3(1.0);
			float spd = floor(speed);
			point = point + vec2(
				sin(time * CN_TAU * spd + r2.x) * r1.x,
				cos(time * CN_TAU * spd + r2.y) * r1.y
			);

			vec2 diff = n + point - f;
			float dist = cnShape(vec2(diff.x, -diff.y), vec2(0.0), metric, cellSize);
			if (metric == 1) {
				dist = abs(n.x + point.x - f.x) + abs(n.y + point.y - f.y);
				dist = dist * cellSize;
			}

			dist = dist + r1.z * (cellVariation * 0.01);
			d = cnSmin(d, dist, cellSmooth * 0.01);
		}
	}
	return d;
}

void main() {
	vec2 resolution = data[0].xy;
	float time = data[0].z;
	int seed = int(data[0].w);

	int metric = int(data[1].x);
	float scale = data[1].y;
	float cellScale = data[1].z;
	float cellSmooth = data[1].w;

	float cellVariation = data[2].x;
	float speed = data[2].y;
	int paletteMode = int(data[2].z);
	int colorMode = int(data[2].w);

	vec3 paletteOffset = data[3].xyz;
	int cyclePalette = int(data[3].w);

	vec3 paletteAmp = data[4].xyz;
	float rotatePalette = data[4].w;

	vec3 paletteFreq = data[5].xyz;
	float repeatPalette = data[5].w;

	vec3 palettePhase = data[6].xyz;

	int texInfluence = int(data[7].x);
	float texIntensity = data[7].y;

	float aspect = resolution.x / resolution.y;

	vec4 color = vec4(0.0, 0.0, 1.0, 1.0);
	vec2 tileOffset = data[8].xy;
	vec2 fullResolution = data[8].zw;
	vec2 st = (gl_FragCoord.xy + tileOffset) / fullResolution.y;

	float freq = cnMap(scale, 1.0, 100.0, 20.0, 1.0);
	float cellSize = cnMap(cellScale, 1.0, 100.0, 3.0, 0.75);

	float texLuminosity = 0.0;
	float texFactor = texIntensity * 0.01;
	vec2 texCoord = (gl_FragCoord.xy + tileOffset) / fullResolution;

	if (texInfluence > 0) {
		vec3 texRGB = texture(tex, texCoord).rgb;

		texLuminosity = cnLuminance(texRGB);

		if (texInfluence == 1) {
			cellSize = cellSize - texLuminosity * texFactor;
		} else if (texInfluence == 2) {
			freq = freq - texLuminosity * (texFactor * 5.0);
		}
	}

	float d = cnCells(st, freq, cellSize, metric, seed, speed, cellVariation, cellSmooth, time, aspect);

	if (texInfluence >= 10) {
		if (texInfluence == 10) {
			d = d + texLuminosity * texFactor;
		} else if (texInfluence == 11) {
			d = mix(d, d / max(0.1, texLuminosity), texFactor);
		} else if (texInfluence == 12) {
			d = mix(d, min(d, texLuminosity), texFactor);
		} else if (texInfluence == 13) {
			d = mix(d, max(d, texLuminosity), texFactor);
		} else if (texInfluence == 14) {
			d = mix(d, cnModulo(d, max(0.1, texLuminosity)), texFactor);
		} else if (texInfluence == 15) {
			d = mix(d, d * texLuminosity, texFactor);
		} else if (texInfluence == 16) {
			d = d - texLuminosity * texFactor;
		}
	}

	if (colorMode == 0) {
		color = vec4(vec3(d, d, d), color.a);
	} else if (colorMode == 1) {
		color = vec4(vec3(1.0 - d), color.a);
	} else if (colorMode == 2) {
		float dd = d;
		if (cyclePalette == -1) {
			dd = dd + time;
		} else if (cyclePalette == 1) {
			dd = dd - time;
		}
		color = vec4(cnPal(dd, paletteOffset, paletteAmp, paletteFreq, palettePhase, paletteMode, rotatePalette, repeatPalette), color.a);
	}

	frag = color;
}

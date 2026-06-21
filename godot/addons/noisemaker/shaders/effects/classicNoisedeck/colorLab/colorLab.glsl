#version 450
// classicNoisedeck/colorLab — single-pass color grading (posterize, dither, color modes,
// hue/saturation/brightness/contrast/invert). Ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/classicNoisedeck/colorLab/wgsl/colorLab.wgsl
// (cross-checked against the reference GLSL).
//
// Single render pass (program "colorLab"). Input-taker: reads inputTex (no-layout effect,
// colorLab.json declares no uniformLayout). The backend SYNTHESIZES the Params UBO and
// injects `#define <name> data[slot].comp` for the 8 engine globals plus every param's
// `uniform` field (colorMode, palette, paletteMode, paletteOffset, paletteAmp,
// paletteFreq, palettePhase, cyclePalette, rotatePalette, repeatPalette, hueRotation,
// hueRange, saturation, invert, brightness, contrast, levels, dither). We use the bare
// names directly. Engine `time`, `resolution` read (bare). Input texture set 0, binding 1.
//
// Int/bool params (brightness, contrast, levels, invert, dither, repeatPalette,
// cyclePalette, paletteMode, colorMode) arrive as float vec4 components, so the WGSL's
// `f32(u.x)` casts are dropped (the bare macro is already a float). `palette` is injected
// but unused (the WGSL never reads it). No reserved-name collisions: no helper takes a
// parameter named like an engine global or param.
//
// WGSL `%` → GLSL `mod()`. WGSL vecNf/vec3u → GLSL vecN/uvec3. gl_FragCoord top-left
// (Godot/Vulkan, matches WGSL) — NO per-effect Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float CL_PI = 3.14159265359;
const float CL_TAU = 6.28318530718;

// PCG PRNG
uvec3 pcg3(uvec3 v_in) {
	uvec3 v = v_in * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v ^= v >> uvec3(16u);
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

vec3 prng(vec3 p) {
	return vec3(pcg3(uvec3(p))) / float(0xffffffffu);
}

float random(vec2 st) {
	return prng(vec3(st, 1.0)).x;
}

float mapVal(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

vec3 posterize(vec3 color, float lev) {
	if (lev == 0.0) {
		return color;
	}
	float lvl = lev;
	if (lvl == 1.0) {
		lvl = 2.0;
	}
	float gamma = 0.65;
	vec3 c = pow(color, vec3(gamma));
	c = floor(c * lvl) / lvl;
	c = pow(c, vec3(1.0 / gamma));
	return c;
}

vec3 brightnessContrast(vec3 color) {
	float bright = mapVal(brightness, -100.0, 100.0, -1.0, 1.0);
	float cont = mapVal(contrast, 0.0, 100.0, 0.0, 2.0);
	return (color - 0.5) * cont + 0.5 + bright;
}

vec3 saturateColor(vec3 color) {
	float sat = mapVal(saturation, -100.0, 100.0, -1.0, 1.0);
	float avg = (color.r + color.g + color.b) / 3.0;
	return color - (avg - color) * sat;
}

float periodicFunction(float p) {
	float x = CL_TAU * p;
	return mapVal(sin(x), -1.0, 1.0, 0.0, 1.0);
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

vec3 linearToSrgb(vec3 linear) {
	vec3 srgb;
	if (linear.r <= 0.0031308) { srgb.r = linear.r * 12.92; }
	else { srgb.r = 1.055 * pow(linear.r, 1.0 / 2.4) - 0.055; }
	if (linear.g <= 0.0031308) { srgb.g = linear.g * 12.92; }
	else { srgb.g = 1.055 * pow(linear.g, 1.0 / 2.4) - 0.055; }
	if (linear.b <= 0.0031308) { srgb.b = linear.b * 12.92; }
	else { srgb.b = 1.055 * pow(linear.b, 1.0 / 2.4) - 0.055; }
	return srgb;
}

vec3 srgbToLinear(vec3 srgb) {
	vec3 linear;
	if (srgb.r <= 0.04045) { linear.r = srgb.r / 12.92; }
	else { linear.r = pow((srgb.r + 0.055) / 1.055, 2.4); }
	if (srgb.g <= 0.04045) { linear.g = srgb.g / 12.92; }
	else { linear.g = pow((srgb.g + 0.055) / 1.055, 2.4); }
	if (srgb.b <= 0.04045) { linear.b = srgb.b / 12.92; }
	else { linear.b = pow((srgb.b + 0.055) / 1.055, 2.4); }
	return linear;
}

// WGSL mat3x3f constructor takes COLUMNS; GLSL mat3(c0,c1,c2) is also column-major.
vec3 linear_srgb_from_oklab(vec3 c) {
	mat3 fwdA = mat3(
		1.0, 1.0, 1.0,
		0.3963377774, -0.1055613458, -0.0894841775,
		0.2158037573, -0.0638541728, -1.2914855480
	);
	mat3 fwdB = mat3(
		4.0767245293, -1.2681437731, -0.0041119885,
		-3.3072168827, 2.6093323231, -0.7034763098,
		0.2307590544, -0.3411344290, 1.7068625689
	);
	vec3 lms = fwdA * c;
	return fwdB * (lms * lms * lms);
}

vec3 pal(float t_in) {
	vec3 a = paletteOffset;
	vec3 b = paletteAmp;
	vec3 c = paletteFreq;
	vec3 d = palettePhase;

	float t = t_in * repeatPalette + rotatePalette * 0.01;
	vec3 color = a + b * cos(6.28318 * (c * t + d));

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

void main() {
	vec2 uv = gl_FragCoord.xy / resolution;

	vec4 color = texture(inputTex, uv);

	if (levels != 0.0) {
		color = vec4(posterize(color.rgb, levels), color.a);
	}

	float bright = rgb2hsv(color.rgb).b;

	if (dither == 1) {
		color = vec4(color.rgb * vec3(step(0.5, bright)), color.a);
	} else if (dither == 2) {
		color = vec4(color.rgb * vec3(step(random(gl_FragCoord.xy), bright)), color.a);
	} else if (dither == 3) {
		color = vec4(color.rgb * vec3(step(periodicFunction(random(gl_FragCoord.xy) + time), bright)), color.a);
	} else if (dither == 4) {
		vec2 coord = mod(gl_FragCoord.xy, 4.0) - 0.5;
		if (bright < 0.12) {
			color = vec4(vec3(0.0), color.a);
		} else if (bright < 0.24) {
			if (coord.x == 1.0 && coord.y == 1.0) { } else { color = vec4(vec3(0.0), color.a); }
		} else if (bright < 0.36) {
			if ((coord.x == 1.0 && coord.y == 1.0) || (coord.x == 3.0 && coord.y == 3.0)) { } else { color = vec4(vec3(0.0), color.a); }
		} else if (bright < 0.48) {
			if ((coord.x == 1.0 || coord.x == 3.0) && (coord.y == 1.0 || coord.y == 3.0)) { } else { color = vec4(vec3(0.0), color.a); }
		} else if (bright < 0.60) {
			if ((coord.x == 1.0 || coord.x == 3.0) && (coord.y == 1.0 || coord.y == 3.0)) { color = vec4(vec3(0.0), color.a); }
		} else if (bright < 0.72) {
			if ((coord.x == 1.0 && coord.y == 1.0) || (coord.x == 3.0 && coord.y == 3.0)) { color = vec4(vec3(0.0), color.a); }
		} else if (bright < 0.84) {
			if (coord.x == 1.0 && coord.y == 1.0) { color = vec4(vec3(0.0), color.a); }
		}
	}

	// color mode
	if (colorMode == 0) {
		color = vec4(vec3(rgb2hsv(color.rgb).b), color.a);
	} else if (colorMode == 1) {
		color = vec4(srgbToLinear(color.rgb), color.a);
	} else if (colorMode == 3) {
		vec3 c = color.rgb;
		c.g = c.g * -0.509 + 0.276;
		c.b = c.b * -0.509 + 0.198;
		c = linear_srgb_from_oklab(c);
		c = linearToSrgb(c);
		color = vec4(c, color.a);
	} else if (colorMode == 4) {
		float d = rgb2hsv(color.rgb).b;
		if (cyclePalette == -1) {
			d += time;
		} else if (cyclePalette == 1) {
			d -= time;
		}
		color = vec4(pal(d), color.a);
	}

	vec3 hsv = rgb2hsv(color.rgb);
	hsv.x = mod(hsv.x * mapVal(hueRange, 0.0, 200.0, 0.0, 2.0) + (hueRotation / 360.0), 1.0);
	color = vec4(hsv2rgb(hsv), color.a);

	if (invert != 0.0) {
		color = vec4(vec3(1.0) - color.rgb, color.a);
	}

	color = vec4(brightnessContrast(color.rgb), color.a);
	color = vec4(saturateColor(color.rgb), color.a);

	frag = color;
}

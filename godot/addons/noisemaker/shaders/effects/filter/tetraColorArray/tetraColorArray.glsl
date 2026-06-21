#version 450
// filter/tetraColorArray — ported PIXEL-IDENTICALLY from wgsl/tetraColorArray.wgsl.
// Applies a discrete color-array gradient (up to 8 colors, auto/manual stops, RGB/HSV/
// OkLab/OKLCH interpolation) to the input by luminance. Single render pass (progName
// "tetraColorArray").
//
// LAYOUT effect (tetraColorArray.json has a `uniformLayout`): this shader declares its OWN
// Params UBO `vec4 data[12]` and reads `data[slot].comp` verbatim from the WGSL — the
// backend does NOT synthesize a layout or inject any #define, so the WGSL locals
// (mode/time/alpha/offset/x/...) are plain locals with no reserved-name collisions. Packing
// matches the JSON uniformLayout:
//   data[0] = (colorMode, colorCount, positionMode, repeat)
//   data[1] = (offset, alpha, smoothness, rotation)
//   data[2] = (color0.rgb, time)
//   data[3..9] = color1..color7 (.xyz)
//   data[10] = positions 0-3, data[11] = positions 4-7
//
// NOTES: WGSL float `%` → GLSL `mod` (watch precedence: `a/d % 6.0` == `mod(a/d, 6.0)`).
// select(a, b, cond) → `cond ? b : a`; vec3 select with vec3<bool> cond → mix(a, b, cond).
// atan2 → atan (same arg order). textureSampleLevel(..,0.0) → texture(..). switch → if/else.
// @builtin(position) → gl_FragCoord (top-left, no flip). textureDimensions → textureSize.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[12]; };
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float TCA_TAU = 6.283185307179586;

// ============================================================================
// Color Space Conversions
// ============================================================================

// --- RGB <-> HSV ---

vec3 hsv2rgb(vec3 hsv) {
	float h = hsv.x;
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float hp = h * 6.0;
	float x = c * (1.0 - abs(mod(hp, 2.0) - 1.0));
	float m = v - c;

	vec3 rgb;
	if (hp < 1.0) {
		rgb = vec3(c, x, 0.0);
	} else if (hp < 2.0) {
		rgb = vec3(x, c, 0.0);
	} else if (hp < 3.0) {
		rgb = vec3(0.0, c, x);
	} else if (hp < 4.0) {
		rgb = vec3(0.0, x, c);
	} else if (hp < 5.0) {
		rgb = vec3(x, 0.0, c);
	} else {
		rgb = vec3(c, 0.0, x);
	}

	return rgb + vec3(m);
}

vec3 rgb2hsv(vec3 c) {
	float cmax = max(c.r, max(c.g, c.b));
	float cmin = min(c.r, min(c.g, c.b));
	float delta = cmax - cmin;

	float h = 0.0;
	if (delta > 0.0) {
		if (cmax == c.r) {
			h = mod((c.g - c.b) / delta, 6.0) / 6.0;
		} else if (cmax == c.g) {
			h = ((c.b - c.r) / delta + 2.0) / 6.0;
		} else {
			h = ((c.r - c.g) / delta + 4.0) / 6.0;
		}
		h = fract(h);
	}
	float s = cmax > 0.0 ? delta / cmax : 0.0;
	return vec3(h, s, cmax);
}

// --- Gamma transfer ---

vec3 linear2srgb(vec3 lin) {
	vec3 low = lin * 12.92;
	vec3 high = 1.055 * pow(max(lin, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
	return mix(high, low, lessThan(lin, vec3(0.0031308)));
}

vec3 srgb2linear(vec3 c) {
	vec3 low = c / 12.92;
	vec3 high = pow((c + 0.055) / 1.055, vec3(2.4));
	return mix(high, low, lessThan(c, vec3(0.04045)));
}

// --- OkLab core ---

vec3 oklab2linear(vec3 lab) {
	float l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
	float m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
	float s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;

	float l = l_ * l_ * l_;
	float m = m_ * m_ * m_;
	float s = s_ * s_ * s_;

	return vec3(
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
	);
}

vec3 linear2oklab(vec3 lin) {
	float l = 0.4122214708 * lin.r + 0.5363325363 * lin.g + 0.0514459929 * lin.b;
	float m = 0.2119034982 * lin.r + 0.6806995451 * lin.g + 0.1073969566 * lin.b;
	float s = 0.0883024619 * lin.r + 0.2817188376 * lin.g + 0.6299787005 * lin.b;

	float l_ = pow(max(l, 0.0), 1.0 / 3.0);
	float m_ = pow(max(m, 0.0), 1.0 / 3.0);
	float s_ = pow(max(s, 0.0), 1.0 / 3.0);

	return vec3(
		0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
		1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
		0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
	);
}

// --- RGB <-> OkLab ---

vec3 oklab2rgb(vec3 lab) {
	return clamp(linear2srgb(oklab2linear(lab)), vec3(0.0), vec3(1.0));
}

vec3 rgb2oklab(vec3 rgb) {
	return linear2oklab(srgb2linear(rgb));
}

// --- RGB <-> OKLCH (L, C, H where H is 0-1 fractional turns) ---

vec3 oklch2rgb(vec3 lch) {
	float a = lch.y * cos(lch.z * TCA_TAU);
	float b = lch.y * sin(lch.z * TCA_TAU);
	return clamp(linear2srgb(oklab2linear(vec3(lch.x, a, b))), vec3(0.0), vec3(1.0));
}

vec3 rgb2oklch(vec3 rgb) {
	vec3 lab = rgb2oklab(rgb);
	float C = length(lab.yz);
	float h = atan(lab.z, lab.y);
	return vec3(lab.x, C, fract(h / TCA_TAU));
}

// --- Dispatch by mode ---

vec3 rgbToColorSpace(vec3 rgb, int mode) {
	if (mode == 1) { return rgb2hsv(rgb); }
	if (mode == 2) { return rgb2oklab(rgb); }
	if (mode == 3) { return rgb2oklch(rgb); }
	return rgb;
}

vec3 colorSpaceToRgb(vec3 color, int mode) {
	if (mode == 1) { return hsv2rgb(color); }
	if (mode == 2) { return oklab2rgb(color); }
	if (mode == 3) { return oklch2rgb(color); }
	return color;
}

// ============================================================================
// Color Array Helpers
// ============================================================================

vec4 getColor(int index) {
	if (index == 0) { return data[2]; }
	if (index == 1) { return data[3]; }
	if (index == 2) { return data[4]; }
	if (index == 3) { return data[5]; }
	if (index == 4) { return data[6]; }
	if (index == 5) { return data[7]; }
	if (index == 6) { return data[8]; }
	if (index == 7) { return data[9]; }
	return data[2];
}

float getPosition(int index, int colorCount, int positionMode) {
	// Auto mode: evenly distribute
	if (positionMode == 0) {
		if (colorCount <= 1) {
			return 0.0;
		}
		return float(index) / float(colorCount - 1);
	}

	// Manual mode: use stored positions
	if (index == 0) { return data[10].x; }
	if (index == 1) { return data[10].y; }
	if (index == 2) { return data[10].z; }
	if (index == 3) { return data[10].w; }
	if (index == 4) { return data[11].x; }
	if (index == 5) { return data[11].y; }
	if (index == 6) { return data[11].z; }
	if (index == 7) { return data[11].w; }
	return 0.0;
}

// Interpolate in color space with shortest-path hue for HSV/OKLCH
vec3 mixInColorSpace(vec3 a, vec3 b, float f, int mode) {
	if (mode == 1) {
		// HSV: hue is .x
		float dh = b.x - a.x;
		if (dh > 0.5) { dh -= 1.0; }
		if (dh < -0.5) { dh += 1.0; }
		return vec3(fract(a.x + dh * f), mix(a.y, b.y, f), mix(a.z, b.z, f));
	} else if (mode == 3) {
		// OKLCH: hue is .z
		float dh = b.z - a.z;
		if (dh > 0.5) { dh -= 1.0; }
		if (dh < -0.5) { dh += 1.0; }
		return vec3(mix(a.x, b.x, f), mix(a.y, b.y, f), fract(a.z + dh * f));
	}
	return mix(a, b, f);
}

vec3 sampleColorArray(float t_in, int colorCount, int positionMode, int colorMode, float smoothAmount) {
	float t = clamp(t_in, 0.0, 1.0);

	// Handle edge cases
	if (colorCount <= 0) {
		return vec3(0.0);
	}
	if (colorCount == 1) {
		return getColor(0).rgb;
	}

	// Cascade blend: smoothstep at each transition boundary
	vec3 result = rgbToColorSpace(getColor(0).rgb, colorMode);

	for (int i = 1; i < colorCount; i = i + 1) {
		float boundary;
		float bw;

		if (positionMode == 0) {
			// Auto: equal-width bands, transitions at i/count
			boundary = float(i) / float(colorCount);
			bw = smoothAmount * 0.5 / float(colorCount);
		} else {
			// Manual: transition at midpoint between adjacent positions
			float pPrev = getPosition(i - 1, colorCount, positionMode);
			float pCurr = getPosition(i, colorCount, positionMode);
			boundary = (pPrev + pCurr) * 0.5;
			bw = smoothAmount * (pCurr - pPrev) * 0.25;
		}

		float blend = smoothstep(boundary - bw, boundary + bw, t);
		vec3 nextColor = rgbToColorSpace(getColor(i).rgb, colorMode);
		result = mixInColorSpace(result, nextColor, blend, colorMode);
	}

	// Wrap-around blend: smooth the seam between last and first color
	if (smoothAmount > 0.0) {
		float bw;
		if (positionMode == 0) {
			bw = smoothAmount * 0.5 / float(colorCount);
		} else {
			float pLast = getPosition(colorCount - 1, colorCount, positionMode);
			float pFirst = getPosition(0, colorCount, positionMode);
			float gap = 1.0 - pLast + pFirst;
			bw = smoothAmount * gap * 0.25;
		}

		if (bw > 0.0) {
			// Signed cyclic distance from the wrap boundary (t=0 == t=1)
			float dd = t > 0.5 ? t - 1.0 : t;
			// Interpolation factor: 0 = last color, 1 = first color
			float wrapFactor = smoothstep(-bw, bw, dd);
			vec3 lastColor = rgbToColorSpace(getColor(colorCount - 1).rgb, colorMode);
			vec3 firstColor = rgbToColorSpace(getColor(0).rgb, colorMode);
			vec3 wrapColor = mixInColorSpace(lastColor, firstColor, wrapFactor, colorMode);

			// Mask: 1.0 at wrap point, fading to 0.0 at edge of zone
			float wrapMask = 1.0 - smoothstep(0.0, bw, abs(dd));
			result = mixInColorSpace(result, wrapColor, wrapMask, colorMode);
		}
	}

	return colorSpaceToRgb(result, colorMode);
}

void main() {
	// Extract uniforms
	int colorMode = int(data[0].x);
	int colorCount = int(data[0].y);
	int positionMode = int(data[0].z);
	float repeatVal = data[0].w;
	float offsetVal = data[1].x;
	float alpha = data[1].y;
	float smoothness = data[1].z;
	int rotation = int(data[1].w);
	float time = data[2].w;

	// Calculate UV from position
	vec2 size = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / size;

	// Get input color
	vec4 inputColor = texture(inputTex, uv);

	// Calculate luminance as the t value
	float lum = dot(inputColor.rgb, vec3(0.299, 0.587, 0.114));

	// Apply mapping: repeat, offset, and rotation (animation)
	float t = lum * (1.0 - 1e-4) * repeatVal + offsetVal;

	if (rotation == -1) {
		t = t + time;
	} else if (rotation == 1) {
		t = t - time;
	}

	t = fract(t);

	// Sample the color array gradient
	vec3 gradientColor = sampleColorArray(t, colorCount, positionMode, colorMode, smoothness);

	// Blend with original based on alpha
	vec3 blendedColor = mix(inputColor.rgb, gradientColor, alpha);

	frag = vec4(blendedColor, inputColor.a);
}

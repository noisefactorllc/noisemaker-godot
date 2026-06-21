#version 450
// filter/palette — ported PIXEL-IDENTICALLY from wgsl/palette.wgsl.
// Apply cosine color palettes based on luminance. Supports RGB, HSV, and OkLab
// colorspaces (mode flag encoded in palette entry amp.w).
//
// No-layout effect: the backend injects the Params UBO + `#define`s for the named
// params (paletteIndex, rotation, offset, repeat, alpha) and engine globals (time),
// so we use the bare reference names directly. paletteIndex/rotation arrive as
// floats and are cast with int(...). Input texture bound at set 0, binding 1.
//
// Helpers (floorMod, hsv_to_rgb, oklab_to_linear_rgb, linear_to_srgb,
// oklab_to_rgb, cosine_palette) are this effect's OWN copies, ported verbatim.
// WGSL select(high, low, linear <= 0.0031308) → mix(high, low, lessThanEqual(...))
// (GLSL mix with bvec selects the second operand where the bool is true, matching
// WGSL select(false_val, true_val, cond)).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Floored modulo (matches GLSL mod behavior for negative values)
float floorMod(float x, float y) {
	return x - y * floor(x / y);
}

struct PaletteEntry {
	vec4 amp;        // .xyz = amplitude, .w = mode (0=rgb, 1=hsv, 2=oklab)
	vec4 freq;
	vec4 palOffset;  // renamed from WGSL `offset` to avoid clash with the offset param
	vec4 phase;
};

// Palette data array (55 entries, index 0 is passthrough so entries start at 1)
// Modes: 0 = RGB, 1 = HSV, 2 = OkLab
const PaletteEntry palettes[55] = PaletteEntry[55](
	// 1: seventiesShirt (rgb)
	PaletteEntry(vec4(0.76, 0.88, 0.37, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.93, 0.97, 0.52, 0.0), vec4(0.21, 0.41, 0.56, 0.0)),
	// 2: fiveG (rgb)
	PaletteEntry(vec4(0.56851584, 0.7740668, 0.23485267, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.727029, 0.08039695, 0.10427457, 0.0)),
	// 3: afterimage (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.3, 0.2, 0.2, 0.0)),
	// 4: barstow (rgb)
	PaletteEntry(vec4(0.45, 0.2, 0.1, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.7, 0.2, 0.2, 0.0), vec4(0.5, 0.4, 0.0, 0.0)),
	// 5: bloob (rgb)
	PaletteEntry(vec4(0.09, 0.59, 0.48, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.2, 0.31, 0.98, 0.0), vec4(0.88, 0.4, 0.33, 0.0)),
	// 6: blueSkies (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.1, 0.4, 0.7, 0.0), vec4(0.1, 0.1, 0.1, 0.0)),
	// 7: brushedMetal (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.0, 0.1, 0.2, 0.0)),
	// 8: burningSky (rgb)
	PaletteEntry(vec4(0.7259015, 0.7004237, 0.9494409, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.63290054, 0.37883538, 0.29405284, 0.0), vec4(0.0, 0.1, 0.2, 0.0)),
	// 9: california (rgb)
	PaletteEntry(vec4(0.94, 0.33, 0.27, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.74, 0.37, 0.73, 0.0), vec4(0.44, 0.17, 0.88, 0.0)),
	// 10: columbia (rgb)
	PaletteEntry(vec4(1.0, 0.7, 1.0, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(1.0, 0.4, 0.9, 0.0), vec4(0.4, 0.5, 0.6, 0.0)),
	// 11: cottonCandy (rgb)
	PaletteEntry(vec4(0.51, 0.39, 0.41, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.59, 0.53, 0.94, 0.0), vec4(0.15, 0.41, 0.46, 0.0)),
	// 12: darkSatin (hsv)
	PaletteEntry(vec4(0.0, 0.0, 0.51, 1.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.0, 0.0, 0.43, 0.0), vec4(0.0, 0.0, 0.36, 0.0)),
	// 13: dealerHat (rgb)
	PaletteEntry(vec4(0.83, 0.45, 0.19, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.79, 0.45, 0.35, 0.0), vec4(0.28, 0.91, 0.61, 0.0)),
	// 14: dreamy (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.0, 0.2, 0.25, 0.0)),
	// 15: eventHorizon (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.22, 0.48, 0.62, 0.0), vec4(0.1, 0.3, 0.2, 0.0)),
	// 16: ghostly (hsv)
	PaletteEntry(vec4(0.02, 0.92, 0.76, 1.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.51, 0.49, 0.51, 0.0), vec4(0.71, 0.23, 0.66, 0.0)),
	// 17: grayscale (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(2.0, 2.0, 2.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0)),
	// 18: hazySunset (rgb)
	PaletteEntry(vec4(0.79, 0.56, 0.22, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.96, 0.5, 0.49, 0.0), vec4(0.15, 0.98, 0.87, 0.0)),
	// 19: heatmap (rgb)
	PaletteEntry(vec4(0.75804377, 0.62868536, 0.2227562, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.35536355, 0.12935615, 0.17060602, 0.0), vec4(0.0, 0.25, 0.5, 0.0)),
	// 20: hypercolor (rgb)
	PaletteEntry(vec4(0.79, 0.5, 0.23, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.75, 0.47, 0.45, 0.0), vec4(0.08, 0.84, 0.16, 0.0)),
	// 21: jester (rgb)
	PaletteEntry(vec4(0.7, 0.81, 0.73, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.1, 0.22, 0.27, 0.0), vec4(0.99, 0.12, 0.94, 0.0)),
	// 22: justBlue (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.5, 0.5, 0.5, 0.0)),
	// 23: justCyan (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(0.0, 1.0, 1.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.5, 0.5, 0.5, 0.0)),
	// 24: justGreen (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.5, 0.5, 0.5, 0.0)),
	// 25: justPurple (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 0.0, 1.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.5, 0.5, 0.5, 0.0)),
	// 26: justRed (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 0.0, 0.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.5, 0.5, 0.5, 0.0)),
	// 27: justYellow (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 0.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.5, 0.5, 0.5, 0.0)),
	// 28: mars (rgb)
	PaletteEntry(vec4(0.74, 0.33, 0.09, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.62, 0.2, 0.2, 0.0), vec4(0.2, 0.1, 0.0, 0.0)),
	// 29: modesto (rgb)
	PaletteEntry(vec4(0.56, 0.68, 0.39, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.72, 0.07, 0.62, 0.0), vec4(0.25, 0.4, 0.41, 0.0)),
	// 30: moss (rgb)
	PaletteEntry(vec4(0.78, 0.39, 0.07, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.0, 0.53, 0.33, 0.0), vec4(0.94, 0.92, 0.9, 0.0)),
	// 31: neptune (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.2, 0.64, 0.62, 0.0), vec4(0.15, 0.2, 0.3, 0.0)),
	// 32: netOfGems (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.64, 0.12, 0.84, 0.0), vec4(0.1, 0.25, 0.15, 0.0)),
	// 33: organic (rgb)
	PaletteEntry(vec4(0.42, 0.42, 0.04, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.47, 0.27, 0.27, 0.0), vec4(0.41, 0.14, 0.11, 0.0)),
	// 34: papaya (rgb)
	PaletteEntry(vec4(0.65, 0.4, 0.11, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.72, 0.45, 0.08, 0.0), vec4(0.71, 0.8, 0.84, 0.0)),
	// 35: radioactive (rgb)
	PaletteEntry(vec4(0.62, 0.79, 0.11, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.22, 0.56, 0.17, 0.0), vec4(0.15, 0.1, 0.25, 0.0)),
	// 36: royal (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.41, 0.22, 0.67, 0.0), vec4(0.2, 0.25, 0.2, 0.0)),
	// 37: santaCruz (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.25, 0.5, 0.75, 0.0)),
	// 38: sherbet (rgb)
	PaletteEntry(vec4(0.6059281, 0.17591387, 0.17166573, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.5224456, 0.3864609, 0.36020845, 0.0), vec4(0.0, 0.25, 0.5, 0.0)),
	// 39: sherbetDouble (rgb)
	PaletteEntry(vec4(0.6059281, 0.17591387, 0.17166573, 0.0), vec4(2.0, 2.0, 2.0, 0.0), vec4(0.5224456, 0.3864609, 0.36020845, 0.0), vec4(0.0, 0.25, 0.5, 0.0)),
	// 40: silvermane (oklab)
	PaletteEntry(vec4(0.42, 0.0, 0.0, 2.0), vec4(2.0, 2.0, 2.0, 0.0), vec4(0.45, 0.5, 0.42, 0.0), vec4(0.63, 1.0, 1.0, 0.0)),
	// 41: skykissed (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.83, 0.6, 0.63, 0.0), vec4(0.3, 0.1, 0.0, 0.0)),
	// 42: solaris (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.6, 0.4, 0.1, 0.0), vec4(0.3, 0.2, 0.1, 0.0)),
	// 43: spooky (oklab)
	PaletteEntry(vec4(0.46, 0.73, 0.19, 2.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.27, 0.79, 0.78, 0.0), vec4(0.27, 0.16, 0.04, 0.0)),
	// 44: springtime (rgb)
	PaletteEntry(vec4(0.67, 0.25, 0.27, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.74, 0.48, 0.46, 0.0), vec4(0.07, 0.79, 0.39, 0.0)),
	// 45: sproingtime (rgb)
	PaletteEntry(vec4(0.9, 0.43, 0.34, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.56, 0.69, 0.32, 0.0), vec4(0.03, 0.8, 0.4, 0.0)),
	// 46: sulphur (rgb)
	PaletteEntry(vec4(0.73, 0.36, 0.52, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.78, 0.68, 0.15, 0.0), vec4(0.74, 0.93, 0.28, 0.0)),
	// 47: summoning (rgb)
	PaletteEntry(vec4(1.0, 0.0, 0.8, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 0.0), vec4(0.0, 0.5, 0.1, 0.0)),
	// 48: superhero (rgb)
	PaletteEntry(vec4(1.0, 0.25, 0.5, 0.0), vec4(0.5, 0.5, 0.5, 0.0), vec4(0.0, 0.0, 0.25, 0.0), vec4(0.5, 0.0, 0.0, 0.0)),
	// 49: toxic (rgb)
	PaletteEntry(vec4(0.5, 0.5, 0.5, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.26, 0.57, 0.03, 0.0), vec4(0.0, 0.1, 0.3, 0.0)),
	// 50: tropicalia (oklab)
	PaletteEntry(vec4(0.28, 0.08, 0.65, 2.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.48, 0.6, 0.03, 0.0), vec4(0.1, 0.15, 0.3, 0.0)),
	// 51: tungsten (rgb)
	PaletteEntry(vec4(0.65, 0.93, 0.73, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.31, 0.21, 0.27, 0.0), vec4(0.43, 0.45, 0.48, 0.0)),
	// 52: vaporwave (rgb)
	PaletteEntry(vec4(0.9, 0.76, 0.63, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.0, 0.19, 0.68, 0.0), vec4(0.43, 0.23, 0.32, 0.0)),
	// 53: vibrant (rgb)
	PaletteEntry(vec4(0.78, 0.63, 0.68, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.41, 0.03, 0.16, 0.0), vec4(0.81, 0.61, 0.06, 0.0)),
	// 54: vintage (rgb)
	PaletteEntry(vec4(0.97, 0.74, 0.23, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.97, 0.38, 0.35, 0.0), vec4(0.34, 0.41, 0.44, 0.0)),
	// 55: vintagePhoto (rgb)
	PaletteEntry(vec4(0.68, 0.79, 0.57, 0.0), vec4(1.0, 1.0, 1.0, 0.0), vec4(0.56, 0.35, 0.14, 0.0), vec4(0.73, 0.9, 0.99, 0.0))
);

// HSV to RGB conversion
vec3 hsv_to_rgb(vec3 hsv) {
	float h = hsv.x;
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float hp = h * 6.0;
	float x = c * (1.0 - abs(floorMod(hp, 2.0) - 1.0));
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

	return rgb + vec3(m, m, m);
}

// OkLab to linear RGB conversion
vec3 oklab_to_linear_rgb(vec3 lab) {
	float L = lab.x;
	float a = lab.y;
	float b = lab.z;

	float l_ = L + 0.3963377774 * a + 0.2158037573 * b;
	float m_ = L - 0.1055613458 * a - 0.0638541728 * b;
	float s_ = L - 0.0894841775 * a - 1.2914855480 * b;

	float l = l_ * l_ * l_;
	float m = m_ * m_ * m_;
	float s = s_ * s_ * s_;

	return vec3(
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
	);
}

// Linear to sRGB conversion (gamma correction)
vec3 linear_to_srgb(vec3 linearColor) {
	vec3 low = linearColor * 12.92;
	vec3 high = 1.055 * pow(linearColor, vec3(1.0 / 2.4)) - 0.055;
	return mix(high, low, lessThanEqual(linearColor, vec3(0.0031308)));
}

// Combined OkLab to sRGB
vec3 oklab_to_rgb(vec3 lab) {
	vec3 labMod = lab;
	labMod.g = labMod.g * -0.509 + 0.276;
	labMod.b = labMod.b * -0.509 + 0.198;
	vec3 linear_rgb = oklab_to_linear_rgb(labMod);
	return clamp(linear_to_srgb(linear_rgb), vec3(0.0), vec3(1.0));
}

// Cosine palette function - IQ formula
vec3 cosine_palette(float t, vec3 amp, vec3 freq, vec3 palOff, vec3 phase) {
	float TAU = 6.283185307179586;
	return clamp(palOff + amp * cos(TAU * (freq * t + phase)), vec3(0.0), vec3(1.0));
}

void main() {
	// Calculate UV from position
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	// Get input color
	vec4 inputColor = texture(inputTex, uv);

	// Get uniforms
	int paletteIndexI = int(paletteIndex);
	int rotationI = int(rotation);

	// Index 0 is passthrough
	if (paletteIndexI <= 0 || paletteIndexI > 55) {
		frag = inputColor;
		return;
	}

	// Calculate luminance as the t value
	float lum = dot(inputColor.rgb, vec3(0.299, 0.587, 0.114));

	// Apply palette modifiers: repeat, offset, and rotation (animation)
	float t = lum * repeat + offset * 0.01;
	if (rotationI == -1) {
		t = t + time;
	} else if (rotationI == 1) {
		t = t - time;
	}

	// Get palette entry (array is 0-indexed, palette indices are 1-indexed)
	PaletteEntry entry = palettes[paletteIndexI - 1];

	// Extract mode from amp.w
	int mode = int(entry.amp.w + 0.5);

	// Apply cosine palette in the appropriate colorspace
	vec3 paletteColor = cosine_palette(t, entry.amp.xyz, entry.freq.xyz, entry.palOffset.xyz, entry.phase.xyz);

	// Convert to RGB based on mode
	vec3 finalColor;
	if (mode == 1) {
		// HSV mode - palette output is HSV, convert to RGB
		finalColor = hsv_to_rgb(paletteColor);
	} else if (mode == 2) {
		// OkLab mode - palette output is OkLab (L, a, b), convert to RGB
		finalColor = oklab_to_rgb(paletteColor);
	} else {
		// RGB mode (default) - no conversion needed
		finalColor = paletteColor;
	}

	// Blend between original and palette color based on alpha
	vec3 blendedColor = mix(inputColor.rgb, finalColor, alpha);

	frag = vec4(blendedColor, inputColor.a);
}

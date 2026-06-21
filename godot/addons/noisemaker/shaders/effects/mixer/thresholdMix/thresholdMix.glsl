#version 450
// mixer/thresholdMix — ported from wgsl/thresholdMix.wgsl. Combines two inputs
// using threshold masking with optional posterization; luminance or per-channel
// RGB thresholding. No-layout effect: backend injects Params UBO + `#define mode …`
// /`quantize …`/`mapSource …`/`threshold …`/`range …`/`thresholdR …`/… etc.
// Two inputs (pass.inputs order): inputTex = source A (binding 1), tex = source B (binding 2).
// getLuminosity / quantizeValue / calculateBlendFactor are this effect's OWN helpers,
// inlined verbatim. The same uv (derived from inputTex's size) samples both inputs.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Convert RGB to luminosity
float getLuminosity(vec3 color) {
	return dot(color, vec3(0.299, 0.587, 0.114));
}

// Quantize a value into discrete bands
float quantizeValue(float value, int bands) {
	if (bands <= 0) {
		return value;
	}
	float numBands = float(bands);
	return floor(value * numBands) / numBands;
}

// Calculate blend factor with threshold and range
// Returns 0 for values below threshold, 1 for values above threshold+range
// Smooth transition in between
float calculateBlendFactor(float mapValue, float thresh, float rng) {
	if (rng <= 0.0) {
		// Hard threshold
		return step(thresh, mapValue);
	} else {
		// Soft threshold with range
		float lower = thresh;
		float upper = thresh + rng;
		return smoothstep(lower, upper, mapValue);
	}
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / dims;

	vec4 colorA = texture(inputTex, uv);
	vec4 colorB = texture(tex, uv);

	// Get map color based on mapSource
	vec3 mapColor;
	if (int(mapSource) == 0) {
		mapColor = colorA.rgb;
	} else {
		mapColor = colorB.rgb;
	}

	// Apply quantization to map values if enabled
	if (int(quantize) > 0) {
		mapColor.x = quantizeValue(mapColor.x, int(quantize));
		mapColor.y = quantizeValue(mapColor.y, int(quantize));
		mapColor.z = quantizeValue(mapColor.z, int(quantize));
	}

	vec4 result;

	if (int(mode) == 0) {
		// Luminance mode - use single threshold for all channels
		float lum = getLuminosity(mapColor);
		float blendFactor = calculateBlendFactor(lum, threshold, range);
		result = mix(colorA, colorB, blendFactor);
	} else {
		// RGB mode - use separate threshold for each channel
		float blendR = calculateBlendFactor(mapColor.x, thresholdR, rangeR);
		float blendG = calculateBlendFactor(mapColor.y, thresholdG, rangeG);
		float blendB = calculateBlendFactor(mapColor.z, thresholdB, rangeB);

		result.x = mix(colorA.x, colorB.x, blendR);
		result.y = mix(colorA.y, colorB.y, blendG);
		result.z = mix(colorA.z, colorB.z, blendB);
		result.w = mix(colorA.w, colorB.w, (blendR + blendG + blendB) / 3.0);
	}

	frag = result;
}

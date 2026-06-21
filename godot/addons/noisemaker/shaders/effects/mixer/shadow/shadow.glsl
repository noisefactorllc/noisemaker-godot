#version 450
// mixer/shadow — ported PIXEL-IDENTICALLY from wgsl/shadow.wgsl. Uses one input as
// a mask to cast an offset, blurred, spread drop-shadow/glow onto the other input.
// No-layout effect: backend injects Params UBO + `#define maskSource …`/`color …`/etc.
// Two inputs (pass.inputs order): inputTex = binding 1, tex = binding 2.
//
// Notes:
//  * getChannel is this effect's OWN helper — ported verbatim inline.
//  * textureSampleLevel(t, samp, uv, 0.0) -> texture(t, uv): the backend binds NEAREST,
//    no mipmaps, so LOD is always 0 — identical to an explicit textureLod(...,0.0). Plain
//    texture() matches the house convention for these blur-loop mixers (see focusBlur).
//  * uv = gl_FragCoord.xy / dims, dims from inputTex (textureSize). NO Y-flip.
//  * maskUV = uv - vec2(offsetX, offsetY) * 0.1 (0.1 literal).
//  * Blur: sigma = max(blur, 0.001); sigma2 = 2*sigma*sigma; x,y in [-5,5] inclusive;
//    offset = vec2(x,y) * blur / dims.
//  * Wrap: hide(0), mirror(1), repeat(2), clamp(3). WGSL `%` operands are non-negative
//    in these expressions, so GLSL mod matches.
//  * int params (maskSource/sourceChannel/wrap) inject as float #defines -> int(...).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Extract a single channel from a color
float getChannel(vec4 c, int channel) {
	if (channel == 0) { return c.r; }
	if (channel == 1) { return c.g; }
	if (channel == 2) { return c.b; }
	return c.a;
}

void main() {
	int maskSrc = int(maskSource);
	int srcChannel = int(sourceChannel);
	int wrapMode = int(wrap);

	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / dims;

	// Base image is the non-mask source. (WGSL used textureSampleLevel here because the
	// blur loop below samples under non-uniform control flow — illegal for implicit
	// derivatives. With NEAREST + no mipmaps, plain texture() samples LOD 0 identically.)
	vec4 baseColor;
	if (maskSrc == 0) {
		baseColor = texture(tex, uv);
	} else {
		baseColor = texture(inputTex, uv);
	}

	// Mask UV shifted by shadow offset
	vec2 maskUV = uv - vec2(offsetX, offsetY) * 0.1;

	// Gaussian blur of thresholded mask
	float shadowMask = 0.0;
	float totalWeight = 0.0;

	float sigma = max(blur, 0.001);
	float sigma2 = 2.0 * sigma * sigma;

	for (int x = -5; x <= 5; x = x + 1) {
		for (int y = -5; y <= 5; y = y + 1) {
			vec2 sampleOffset = vec2(float(x), float(y)) * blur / dims;
			vec2 sampleUV = maskUV + sampleOffset;

			// Apply wrap mode to sample UVs
			float thresholded = 0.0;
			if (wrapMode == 0) {
				// hide: treat out-of-bounds as empty
				if (sampleUV.x >= 0.0 && sampleUV.x <= 1.0 && sampleUV.y >= 0.0 && sampleUV.y <= 1.0) {
					vec4 maskSample;
					if (maskSrc == 0) {
						maskSample = texture(inputTex, sampleUV);
					} else {
						maskSample = texture(tex, sampleUV);
					}
					thresholded = step(threshold, getChannel(maskSample, srcChannel));
				}
			} else {
				vec2 wrappedUV = sampleUV;
				if (wrapMode == 1) {
					// mirror
					wrappedUV = abs(mod(mod(sampleUV + 1.0, 2.0) + 2.0, 2.0) - 1.0);
				} else if (wrapMode == 2) {
					// repeat
					wrappedUV = mod(mod(sampleUV, 1.0) + 1.0, 1.0);
				} else {
					// clamp
					wrappedUV = clamp(sampleUV, vec2(0.0), vec2(1.0));
				}
				vec4 maskSample;
				if (maskSrc == 0) {
					maskSample = texture(inputTex, wrappedUV);
				} else {
					maskSample = texture(tex, wrappedUV);
				}
				thresholded = step(threshold, getChannel(maskSample, srcChannel));
			}

			float dist2 = float(x * x + y * y);
			float weight = exp(-dist2 / sigma2);

			shadowMask = shadowMask + thresholded * weight;
			totalWeight = totalWeight + weight;
		}
	}
	shadowMask = shadowMask / totalWeight;

	// Spread amplifies the mask to expand the shadow
	shadowMask = clamp(shadowMask * (1.0 + spread), 0.0, 1.0);

	// Composite shadow onto base
	vec3 withShadow = mix(baseColor.rgb, color, shadowMask);

	// Composite mask source (foreground) on top of the shadow
	vec4 fgSample;
	if (maskSrc == 0) {
		fgSample = texture(inputTex, uv);
	} else {
		fgSample = texture(tex, uv);
	}
	float fgMask = step(threshold, getChannel(fgSample, srcChannel));
	vec3 result = mix(withShadow, fgSample.rgb, fgMask);

	frag = vec4(result, baseColor.a);
}

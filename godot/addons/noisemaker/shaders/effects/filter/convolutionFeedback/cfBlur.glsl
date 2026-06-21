#version 450
// filter/convolutionFeedback program "cfBlur" — ported from wgsl/cfBlur.wgsl.
// Gaussian blur pass (2nd of 3) of the FEEDBACK effect. Reads the sharpened intermediate
// (_cfSharpened, binding 1) and writes the blurred result to _cfBlurred.
//
// No-layout effect: backend SYNTHESIZES the Params UBO + `#define <name> data[slot].comp`
// for the params; use bare names. Int param blurRadius arrives as float → int(blurRadius).
// The WGSL's `Uniforms` struct is just the reference packing.
//
// WGSL→GLSL: textureDimensions→textureSize; textureLoad→texelFetch (integer coords, no
// sampler — matches the WGSL). gl_FragCoord top-left/+0.5, NO Y-flip. `amount`/`radius`
// renamed to `blurAmt`/`blurRad` locals (blurAmount/blurRadius are injected param defines).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 texSize = textureSize(inputTex, 0);
	ivec2 coord = ivec2(gl_FragCoord.xy);

	vec4 center = texelFetch(inputTex, coord, 0);
	int blurRad = int(blurRadius);
	float blurAmt = blurAmount;

	if (blurRad <= 0 || blurAmt <= 0.0) {
		frag = center;
		return;
	}

	// Compute sigma for Gaussian (radius ~= 2*sigma for good coverage)
	float sigma = float(blurRad) / 2.0;
	float sigma2 = sigma * sigma;

	vec3 sum = vec3(0.0);
	float weightSum = 0.0;

	for (int ky = -blurRad; ky <= blurRad; ky = ky + 1) {
		for (int kx = -blurRad; kx <= blurRad; kx = kx + 1) {
			ivec2 samplePos = coord + ivec2(kx, ky);
			samplePos = clamp(samplePos, ivec2(0), texSize - ivec2(1));

			float dist2 = float(kx * kx + ky * ky);
			float weight = exp(-dist2 / (2.0 * sigma2));

			vec4 texSample = texelFetch(inputTex, samplePos, 0);
			sum = sum + texSample.rgb * weight;
			weightSum = weightSum + weight;
		}
	}

	vec3 blurred = sum / weightSum;

	// Mix between original and blurred based on blurAmount
	vec3 result = mix(center.rgb, blurred, blurAmt);

	frag = vec4(result, center.a);
}

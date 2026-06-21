#version 450
// mixer/focusBlur — ported from wgsl/focusBlur.wgsl. Focus blur (depth of field):
// reconstructs a faux depth buffer from luminance to drive a 9x9 Gaussian blur whose
// radius grows with distance from the focal plane. No-layout effect: backend injects
// the Params UBO + `#define depthSource …`/`focalDistance …`/`aperture …`/`sampleBias …`.
// Two inputs (pass.inputs order): inputTex (binding 1), tex (binding 2).
// NOTE: WGSL helper param `resolution` collides with the injected engine name — renamed
// to `res` (pure symbol rename, matches the HLSL port's `resolutionDims`).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Convert RGB to luminosity for depth estimation
float getLuminosity(vec3 color) {
	return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

// Compute blur factor based on depth distance from focal plane
float computeBlurFactor(float depth) {
	float focalPlane = focalDistance * 0.01;
	float blur = abs(depth - focalPlane) * aperture;
	return clamp(blur, 0.0, 1.0);
}

// Apply depth of field blur using inputTex as scene, tex as depth
vec4 applyFocusBlurAB(vec2 uv, vec2 res) {
	// Sample depth texture and compute luminosity as depth proxy
	vec4 depthSample = texture(inputTex, uv);
	float depth = getLuminosity(depthSample.rgb);

	// Calculate blur amount based on distance from focal plane
	float blurFactor = computeBlurFactor(depth) * 10.0;

	vec4 color = vec4(0.0);
	float totalWeight = 0.0;

	// Gaussian blur convolution kernel (9x9)
	for (int x = -4; x <= 4; x = x + 1) {
		for (int y = -4; y <= 4; y = y + 1) {
			vec2 offset = vec2(float(x), float(y)) * sampleBias / res;

			// Gaussian weight based on distance from center
			float dist2 = float(x * x + y * y);
			float sigma2 = 2.0 * blurFactor * blurFactor;
			float weight = exp(-dist2 / max(sigma2, 0.001));

			color = color + texture(tex, uv + offset) * weight;
			totalWeight = totalWeight + weight;
		}
	}

	return color / totalWeight;
}

// Apply depth of field blur using tex as scene, inputTex as depth
vec4 applyFocusBlurBA(vec2 uv, vec2 res) {
	// Sample depth texture and compute luminosity as depth proxy
	vec4 depthSample = texture(tex, uv);
	float depth = getLuminosity(depthSample.rgb);

	// Calculate blur amount based on distance from focal plane
	float blurFactor = computeBlurFactor(depth) * 10.0;

	vec4 color = vec4(0.0);
	float totalWeight = 0.0;

	// Gaussian blur convolution kernel (9x9)
	for (int x = -4; x <= 4; x = x + 1) {
		for (int y = -4; y <= 4; y = y + 1) {
			vec2 offset = vec2(float(x), float(y)) * sampleBias / res;

			// Gaussian weight based on distance from center
			float dist2 = float(x * x + y * y);
			float sigma2 = 2.0 * blurFactor * blurFactor;
			float weight = exp(-dist2 / max(sigma2, 0.001));

			color = color + texture(inputTex, uv + offset) * weight;
			totalWeight = totalWeight + weight;
		}
	}

	return color / totalWeight;
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / dims;

	vec4 color;

	// depthSource: 0 = use inputTex (A) as depth map, blur tex (B)
	//              1 = use tex (B) as depth map, blur inputTex (A)
	if (int(depthSource) == 0) {
		color = applyFocusBlurAB(uv, dims);
	} else {
		color = applyFocusBlurBA(uv, dims);
	}

	// Preserve maximum alpha from both sources
	float alpha1 = texture(inputTex, uv).a;
	float alpha2 = texture(tex, uv).a;
	color.a = max(alpha1, alpha2);

	frag = color;
}

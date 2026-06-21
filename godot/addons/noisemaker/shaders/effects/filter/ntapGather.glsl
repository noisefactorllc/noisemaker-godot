#version 450
// filter/bloom program "ntapGather" — ported from wgsl/ntapGather.wgsl.
// Samples the bright texture with a configurable radially symmetric kernel: a
// golden-angle spiral (Poisson-ish disk) with Gaussian-ish radial falloff,
// energy-normalized. NOTE: radiusUV = radius * texelSize per the WGSL (NO
// renderScale multiply — the reference GLSL scales by renderScale, the canonical
// WGSL does not; at renderScale==1 they agree).
// No-layout effect: backend injects Params UBO + `#define radius …`/`taps …` and
// engine globals. Input (_brightTex) bound at set 0, binding 1 (pass.inputs order).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Golden angle for Poisson-like disk distribution
const float GOLDEN_ANGLE = 2.39996323;
const int MAX_TAPS = 64;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec2 texelSize = 1.0 / texSize;

	// Bloom radius in UV space
	vec2 radiusUV = radius * texelSize;

	// Clamp taps to valid range
	int tapCount = clamp(int(taps), 1, MAX_TAPS);

	vec3 bloomAccum = vec3(0.0);
	float weightSum = 0.0;

	// Generate N-tap kernel using golden angle spiral (Poisson-ish distribution)
	// with Gaussian-like radial falloff for weights
	for (int i = 0; i < MAX_TAPS; i++) {
		if (i >= tapCount) { break; }

		// Compute tap offset using golden angle spiral
		// r goes from 0 to 1 as sqrt(i/N) for uniform area distribution
		float t = float(i) / float(tapCount);
		float r = sqrt(t);
		float theta = float(i) * GOLDEN_ANGLE;

		vec2 offset = vec2(cos(theta), sin(theta)) * r;

		// Gaussian-ish weight based on distance from center
		float sigma = 0.4;
		float weight = exp(-0.5 * (r * r) / (sigma * sigma));

		// Sample with clamped UV (edge handling)
		vec2 sampleUV = clamp(uv + offset * radiusUV, vec2(0.0), vec2(1.0));
		vec3 sampleColor = texture(inputTex, sampleUV).rgb;

		bloomAccum += sampleColor * weight;
		weightSum += weight;
	}

	// Normalize for energy conservation
	if (weightSum > 0.0) {
		bloomAccum /= weightSum;
	}

	frag = vec4(bloomAccum, 1.0);
}

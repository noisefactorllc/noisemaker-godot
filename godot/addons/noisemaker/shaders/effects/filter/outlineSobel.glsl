#version 450
// filter/outline program "outlineSobel" — ported from wgsl/outlineSobel.wgsl.
// Pass 2 of 3: 3x3 Sobel edge detection on the value map, with a configurable
// distance metric (Euclidean/Manhattan/Chebyshev/Octagram) and integer thickness
// that scales the neighbourhood step. Wrap-around addressing via wrapCoord.
// No-layout effect: backend injects the Params UBO + engine globals. Input
// (valueTexture = outlineValueMap) bound at set 0, binding 1 (pass.inputs order).
//
// PORTING NOTES:
//  * WGSL textureLoad(valueTexture, ivec2, 0) -> texelFetch (exact integer texel
//    fetch, no interpolation). coord = ivec2(gl_FragCoord.xy) (the WGSL @builtin
//    position truncated to int) — matching normalMap.glsl's texelFetch path.
//  * offset = max(1, int(thickness)) — WGSL is canonical and has NO renderScale
//    multiply (the reference GLSL multiplies thickness*renderScale; at
//    renderScale==1 they agree). thickness is the injected param #define.
//  * metric = int(sobelMetric) truncation. Octagram divisor literal is 1.414
//    exactly. Magnitude boost * 4.0 reproduced literally.
layout(set = 0, binding = 1) uniform sampler2D valueTexture;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

int wrapCoord(int value, int size) {
	if (size <= 0) {
		return 0;
	}
	int wrapped = value % size;
	if (wrapped < 0) {
		wrapped = wrapped + size;
	}
	return wrapped;
}

float distanceMetric(float gx, float gy, int metric) {
	float abs_gx = abs(gx);
	float abs_gy = abs(gy);

	if (metric == 2) {
		// Manhattan
		return abs_gx + abs_gy;
	} else if (metric == 3) {
		// Chebyshev
		return max(abs_gx, abs_gy);
	} else if (metric == 4) {
		// Octagram
		float cross = (abs_gx + abs_gy) / 1.414;
		return max(cross, max(abs_gx, abs_gy));
	} else {
		// Euclidean (default)
		return sqrt(gx * gx + gy * gy);
	}
}

void main() {
	ivec2 dimensions = textureSize(valueTexture, 0);
	if (dimensions.x == 0 || dimensions.y == 0) {
		frag = vec4(0.0);
		return;
	}

	ivec2 coord = ivec2(gl_FragCoord.xy);
	int metric = int(sobelMetric);

	// Sample 3x3 neighborhood with thickness scaling
	int offset = max(1, int(thickness));
	float samples[9];
	int idx = 0;
	for (int ky = -1; ky <= 1; ky = ky + 1) {
		for (int kx = -1; kx <= 1; kx = kx + 1) {
			int sampleX = wrapCoord(coord.x + kx * offset, dimensions.x);
			int sampleY = wrapCoord(coord.y + ky * offset, dimensions.y);
			samples[idx] = texelFetch(valueTexture, ivec2(sampleX, sampleY), 0).r;
			idx = idx + 1;
		}
	}

	// Sobel X kernel: [-1 0 1; -2 0 2; -1 0 1]
	float gx = -samples[0] + samples[2] - 2.0*samples[3] + 2.0*samples[5] - samples[6] + samples[8];

	// Sobel Y kernel: [-1 -2 -1; 0 0 0; 1 2 1]
	float gy = -samples[0] - 2.0*samples[1] - samples[2] + samples[6] + 2.0*samples[7] + samples[8];

	float magnitude = distanceMetric(gx, gy, metric);
	// Boost edge visibility - multiply by 4 to make edges more visible
	float normalized = clamp(magnitude * 4.0, 0.0, 1.0);

	frag = vec4(normalized, normalized, normalized, 1.0);
}

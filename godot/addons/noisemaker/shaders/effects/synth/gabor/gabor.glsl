#version 450
// synth/gabor — ported from wgsl/gabor.wgsl (top-left origin = Godot/Vulkan,
// no Y-flip). Anisotropic bandlimited noise via sparse Gabor convolution: each
// grid cell scatters random impulse points; the value is the sum of Gabor kernel
// contributions from the 3x3 cell neighborhood, fractal-summed over octaves, then
// squashed through a logistic curve. Packed uniformLayout: vec4 data[4]
// (effects/synth/gabor.json). pcg/prng/map are nm_core's shared primitives — this
// WGSL's inline copies are bit-identical (fold variant, divisor float(0xffffffffu)).
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[4]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// gaborNoise — sum Gabor kernels from the 3x3 cell neighborhood (verbatim).
float gaborNoise(vec2 st, float freq, float sigma, float baseAngle, float iso, int impulses, float t, float sd) {
	vec2 cell = floor(st);
	vec2 fr = fract(st);
	float sum = 0.0;

	for (int dy = -1; dy <= 1; dy = dy + 1) {
		for (int dx = -1; dx <= 1; dx = dx + 1) {
			vec2 neighbor = vec2(float(dx), float(dy));
			vec2 cellId = cell + neighbor;

			for (int k = 0; k < 8; k = k + 1) {
				if (k >= impulses) { break; }

				vec3 r1 = prng(vec3(cellId, sd + float(k) * 7.0));
				vec3 r2 = prng(vec3(sd + float(k) * 13.0, cellId));

				vec2 impulsePos = r1.xy;
				impulsePos = impulsePos + vec2(sin(t + r2.x * TAU), cos(t + r2.y * TAU)) * 0.15;

				vec2 delta = neighbor + impulsePos - fr;

				float angle = mix(baseAngle, r2.z * TAU, iso);
				vec2 dir = vec2(cos(angle), sin(angle));

				float weight = 1.0;
				if (r1.z < 0.5) { weight = -1.0; }

				float envelope = exp(-dot(delta, delta) / (2.0 * sigma * sigma));
				float phase = TAU * freq * dot(dir, delta);
				sum = sum + weight * envelope * cos(phase);
			}
		}
	}
	return sum;
}

void main() {
	vec2 resolution = data[0].xy;
	float time = data[0].z;
	float seed = data[0].w;

	float scale = data[1].x;
	float orientation = data[1].y;
	float bandwidth = data[1].z;
	float isotropy = data[1].w;

	float density = data[2].x;
	float octaves = data[2].y;
	float speed = data[2].z;
	vec2 tileOffset = data[3].xy;
	vec2 fullResolution = data[3].zw;
	vec2 st = (gl_FragCoord.xy + tileOffset) / fullResolution.y;

	float freq = map(scale, 1.0, 100.0, 20.0, 1.0);
	float sigma = map(bandwidth, 1.0, 100.0, 0.05, 0.35);
	float baseAngle = orientation * PI / 180.0;
	float iso = isotropy / 100.0;
	int impulses = int(density);
	int oct = int(octaves);
	float spd = floor(speed);
	float t = time * TAU * spd;

	vec2 p = st * freq;

	// Fractal octave summation
	float value = 0.0;
	float amplitude = 1.0;
	float totalAmp = 0.0;
	vec2 pOct = p;

	for (int i = 0; i < 5; i = i + 1) {
		if (i >= oct) { break; }
		float octFreq = 1.0 + float(i) * 0.5;
		float octSigma = sigma / (1.0 + float(i) * 0.5);
		float fi = float(i);
		value = value + amplitude * gaborNoise(pOct, octFreq, octSigma, baseAngle, iso, impulses, t + fi * 3.7, seed + fi * 17.0);
		totalAmp = totalAmp + amplitude;
		amplitude = amplitude * 0.5;
		pOct = pOct * 2.0;
	}
	value = value / totalAmp;

	float n = 1.0 / (1.0 + exp(-value * 3.0));
	frag = vec4(vec3(n), 1.0);
}

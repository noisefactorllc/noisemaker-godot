#version 450
// filter/octaveWarp — ported from wgsl/octaveWarp.wgsl (top-left origin = Godot/Vulkan,
// no Y-flip). Per-octave value-noise domain warp: each octave generates noise at
// frequency x 2^i, displaces the sample coordinate, and finally samples the input at
// the warped position (displacement decreases per octave, / 2^i). Single render pass
// with optional 4-tap screen-space antialiasing.
//
// No-layout effect (effects/filter/octaveWarp.json has no uniformLayout): the backend
// injects the Params UBO + `#define frequency …`/`octaves`/`displacement`/`speed`/
// `seed`/`wrap` (synthesized layout) and engine globals (`time`), so bare reference
// names are used directly. Input texture bound at set 0, binding 1.
//
// pcg is byte-identical to nm_core's, so it is reused. hash21 only sign-folds x/y and
// passes seed directly as z (it is NOT the full prng fold), so it is inlined verbatim.
// TAU here uses the WGSL's full-precision literal (renamed to avoid nm_core's TAU).
#include "include/nm_core.glsl"

layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float OCTAVEWARP_TAU = 6.28318530717959;

// hash21 — pcg(uvec3(fold(p.x), fold(p.y), seed)).x / float(0xffffffffu).
// select(a, b, cond) -> cond ? b : a (operands reversed). float->uint is truncation.
float hash21(vec2 p) {
	uvec3 v = pcg(uvec3(
		uint(p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0),
		uint(p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0),
		uint(seed)
	));
	return float(v.x) / float(0xffffffffu);
}

// noise — value noise with smoothstep interpolation (verbatim).
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 ff = f * f * (3.0 - 2.0 * f);

	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));

	return mix(mix(a, b, ff.x), mix(c, d, ff.x), ff.y);
}

// simplexNoise — multi-octave noise on a circular path so t=0 and t=1 are seamless;
// phase offsets the angle per octave, radius scales the circular path (verbatim).
float simplexNoise(vec2 p, float t, float phase, float radius) {
	float angle = t * OCTAVEWARP_TAU + phase;
	float cx = cos(angle) * radius;
	float cy = sin(angle) * radius;
	float n = noise(p + vec2(cx, cy));
	n = n + noise(p * 2.0 + vec2(-cy, cx) * 0.75) * 0.5;
	n = n + noise(p * 4.0 + vec2(cx, -cy) * 0.5) * 0.25;
	return n / 1.75;
}

// wrapFloat — mode: 0=mirror, 1=repeat, 2(default)=clamp. Mirror branch open-codes
// the periodic reduction; clamp branch clamps the raw value (all verbatim from WGSL).
float wrapFloat(float value, float limit, int mode) {
	if (limit <= 0.0) {
		return 0.0;
	}
	float norm = value / limit;
	if (mode == 0) {
		// Mirror: abs(mod(norm + 1, 2) - 1)
		float m = (norm + 1.0) - floor((norm + 1.0) * 0.5) * 2.0;
		return abs(m - 1.0) * limit;
	} else if (mode == 1) {
		// Repeat
		return (norm - floor(norm)) * limit;
	}
	// Clamp
	return clamp(value, 0.0, limit);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	float width = texSize.x;
	float height = texSize.y;

	// Adjust frequency for aspect ratio
	float baseFreq = 11.0 - frequency;
	float aspect = width / height;
	vec2 freq = vec2(baseFreq);
	if (aspect > 1.0) {
		freq.y = freq.y * aspect;
	} else {
		freq.x = freq.x / aspect;
	}

	vec2 uv = gl_FragCoord.xy / texSize;
	vec2 sampleCoord = uv * texSize;

	int numOctaves = max(int(octaves), 1);
	float displaceBase = displacement;

	// Per-octave warping
	for (int octave = 1; octave <= 10; octave = octave + 1) {
		if (octave > numOctaves) {
			break;
		}

		float multiplier = pow(2.0, float(octave));
		vec2 freqScaled = freq * 0.5 * multiplier;

		if (freqScaled.x >= width || freqScaled.y >= height) {
			break;
		}

		// Per-octave phase and radius break up uniform circular motion
		float phase = float(octave) * 2.399;  // golden angle
		float radius = 0.5 / sqrt(multiplier);

		// Compute reference angles from noise
		vec2 noiseCoord = (sampleCoord / texSize) * freqScaled;
		float refX = simplexNoise(noiseCoord + vec2(17.0, 29.0), time * float(speed), phase, radius) * 2.0 - 1.0;
		float refY = simplexNoise(noiseCoord + vec2(23.0, 31.0), time * float(speed), phase, radius) * 2.0 - 1.0;

		// Calculate displacement (decreases with each octave)
		float displaceScale = displaceBase / multiplier;
		vec2 offset = vec2(refX * displaceScale * width, refY * displaceScale * height);

		sampleCoord = sampleCoord + offset;
		sampleCoord = vec2(
			wrapFloat(sampleCoord.x, width, int(wrap)),
			wrapFloat(sampleCoord.y, height, int(wrap))
		);
	}

	vec2 finalUV = vec2(
		wrapFloat(sampleCoord.x, width, int(wrap)),
		wrapFloat(sampleCoord.y, height, int(wrap))
	) / texSize;

	if (antialias != 0) {
		vec2 dx = dFdx(finalUV);
		vec2 dy = dFdy(finalUV);
		vec4 col = vec4(0.0);
		col += texture(inputTex, finalUV + dx * -0.375 + dy * -0.125);
		col += texture(inputTex, finalUV + dx *  0.125 + dy * -0.375);
		col += texture(inputTex, finalUV + dx *  0.375 + dy *  0.125);
		col += texture(inputTex, finalUV + dx * -0.125 + dy *  0.375);
		frag = col * 0.25;
	} else {
		frag = texture(inputTex, finalUV);
	}
}

#version 450
// filter/corrupt — ported PIXEL-IDENTICALLY from wgsl/corrupt.wgsl. Scanline data
// corruption: per-row staggered-time hashing drives pixel-sort, byte-shift, bit
// quantize/XOR/shift, channel separation, melt drip, and scatter displacement. Single
// render pass (progName "corrupt").
//
// LAYOUT effect (corrupt.json has a `uniformLayout`): this shader declares its OWN
// Params UBO and reads `data[slot].comp` exactly as the WGSL — the backend does NOT
// synthesize a layout or inject any #define here, so there are NO reserved-name macro
// collisions (the WGSL locals `time`/`seed`/`resolution`/etc. are plain locals). The
// packing matches the JSON uniformLayout:
//   data[0] = (time, seed, intensity, sort)
//   data[1] = (shift, bits, channelShift, speed)
//   data[2] = (melt, scatter, bandHeight, _)
//
// COORDINATE NOTE: ported from WGSL (top-left): resolution = textureSize(inputTex), uv =
// gl_FragCoord.xy / resolution, row = gl_FragCoord.y. We do NOT reproduce the reference
// GLSL's tileOffset/fullResolution/renderScale remap (the WGSL has none). WGSL
// `textureSampleLevel(.., 0.0)` → `texture(..)` (the branches that disqualified plain
// textureSample in WGSL are not a constraint in GLSL). WGSL float `%` → GLSL `mod` (none
// here; uses fract). No arithmetic reassociation.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[3]; };
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

#define CR_PI 3.14159265359
#define CR_TAU 6.28318530718

// PCG PRNG - MIT License
uvec3 pcg(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v = v ^ (v >> uvec3(16u));
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

vec3 prng(vec3 p0) {
	vec3 p = p0;
	if (p.x >= 0.0) { p.x = p.x * 2.0; } else { p.x = -p.x * 2.0 + 1.0; }
	if (p.y >= 0.0) { p.y = p.y * 2.0; } else { p.y = -p.y * 2.0 + 1.0; }
	if (p.z >= 0.0) { p.z = p.z * 2.0; } else { p.z = -p.z * 2.0 + 1.0; }
	uvec3 u = pcg(uvec3(p));
	return vec3(u) / float(0xffffffffu);
}

float rowTime(float row, float sd, float t) {
	float phase = prng(vec3(row, sd + 777.0, 0.0)).x;
	return floor((t + phase) * 8.0);
}

vec3 lineHash(float line, float sd, float rt) {
	return prng(vec3(line, sd, rt));
}

vec2 pixelSort(vec2 uv_in, float row, float sortAmt, float rt, float sd, float resX) {
	vec2 uv = uv_in;
	vec3 rh = lineHash(row, sd, rt);
	float threshold = mix(0.8, 0.2, sortAmt);
	float regionSize = 3.0 + rh.y * 20.0;
	float region = floor(uv.x * resX / regionSize);
	vec3 regionHash = prng(vec3(region, row, sd + rt));
	float regionPos = fract(uv.x * resX / regionSize);
	float sortShift = regionPos * regionHash.x * sortAmt * 0.15;
	if (regionHash.y > threshold) {
		uv.x = fract(uv.x + sortShift);
	}
	return uv;
}

vec2 byteShift(vec2 uv_in, float row, float shiftAmt, float rt, float sd, float resX) {
	vec2 uv = uv_in;
	vec3 rh = lineHash(row, sd, rt);
	float chunkWidth = 8.0 + rh.x * 80.0;
	float chunk = floor(uv.x * resX / chunkWidth);
	vec3 ch = prng(vec3(chunk, row + 200.0, sd + rt));
	float shiftPx = (ch.x - 0.5) * 2.0 * shiftAmt * resX * 0.15;
	float sparsity = mix(0.85, 0.3, shiftAmt);
	if (ch.y > sparsity) {
		uv.x = fract(uv.x + shiftPx / resX);
	}
	return uv;
}

vec3 bitCorrupt(vec3 color_in, vec2 uv, float row, float bitAmt, float rt, float sd, float resX) {
	vec3 color = color_in;
	vec3 bh = lineHash(row + 400.0, sd, rt);
	float levels = mix(256.0, 2.0, bitAmt * bitAmt);
	color = floor(color * levels + 0.5) / levels;
	if (bitAmt > 0.3) {
		float xorStrength = (bitAmt - 0.3) / 0.7;
		float px = floor(uv.x * resX);
		vec3 xorHash = prng(vec3(px, row, sd + rt + 500.0));
		vec3 mask = step(vec3(1.0 - xorStrength * 0.5), xorHash);
		color = mix(color, 1.0 - color, mask);
	}
	if (bitAmt > 0.6) {
		float shiftStr = (bitAmt - 0.6) / 0.4;
		float bitShift = floor(bh.x * 4.0) + 1.0;
		float scale = pow(2.0, bitShift);
		color = fract(color * mix(1.0, scale, shiftStr));
	}
	return color;
}

vec2 meltDisplace(vec2 uv_in, float meltAmt, float t, float sd, float resX) {
	vec2 uv = uv_in;
	float col = floor(uv.x * resX / 3.0);
	float colPhase = prng(vec3(col, sd + 601.0, 0.0)).x;
	vec3 dripHash = prng(vec3(col, sd + 600.0, floor((t + colPhase) * 8.0)));
	float gravity = (1.0 - uv.y) * (1.0 - uv.y);
	float dripAmt = dripHash.x * meltAmt * gravity * 0.4;
	float dripProb = mix(0.9, 0.2, meltAmt);
	if (dripHash.y > dripProb) {
		float wobble = sin(uv.y * 20.0 + dripHash.z * CR_TAU + t) * meltAmt * 0.02;
		uv.y = clamp(uv.y + dripAmt, 0.0, 1.0);
		uv.x = fract(uv.x + wobble);
	}
	return uv;
}

vec2 scatterDisplace(vec2 uv_in, float scatterAmt, float t, float sd, vec2 fragCoord) {
	vec2 uv = uv_in;
	vec3 phaseHash = prng(vec3(floor(fragCoord), sd + 700.0));
	float pixTime = floor((t + phaseHash.x) * 8.0);
	vec3 pixHash = prng(vec3(floor(fragCoord), pixTime + sd));
	float threshold = mix(0.98, 0.1, scatterAmt * scatterAmt);
	if (pixHash.x > threshold) {
		vec3 dirHash = prng(vec3(floor(fragCoord) + vec2(1000.0), pixTime + sd));
		float dist = scatterAmt * 0.15 * (0.5 + pixHash.y * 0.5);
		uv.x = fract(uv.x + (dirHash.x - 0.5) * dist);
		uv.y = clamp(uv.y + (dirHash.y - 0.5) * dist, 0.0, 1.0);
	}
	return uv;
}

void main() {
	float time = data[0].x;
	float seed = data[0].y;
	float intensity = data[0].z;
	float sort = data[0].w;

	float shift = data[1].x;
	float bits = data[1].y;
	float channelShift = data[1].z;
	float speed = data[1].w;

	float melt = data[2].x;
	float scatter = data[2].y;
	float bandHeight = data[2].z;

	vec2 resolution = vec2(textureSize(inputTex, 0));
	float resX = resolution.x;
	vec2 uv = gl_FragCoord.xy / resolution;
	float spd = floor(speed);
	float t = time * CR_TAU * spd;

	// Scanline grouping.
	float rawRow = gl_FragCoord.y;
	float bh = max(1.0, floor(bandHeight * 0.32));
	float row = floor(rawRow / bh);

	// Per-row staggered time.
	float rt = rowTime(row, seed, t);

	// Per-scanline corruption probability.
	vec3 rowHash = lineHash(row, seed, rt);
	float prob = intensity / 100.0;
	bool isCorrupt = rowHash.x < prob;

	vec2 sampleUv = uv;

	// 2D effects (not band-based).
	float meltAmt = melt / 100.0;
	if (meltAmt > 0.0) {
		sampleUv = meltDisplace(sampleUv, meltAmt, t, seed, resX);
	}
	float scatterAmt = scatter / 100.0;
	if (scatterAmt > 0.0) {
		sampleUv = scatterDisplace(sampleUv, scatterAmt, t, seed, gl_FragCoord.xy);
	}

	// Band-based corruption to UV.
	if (isCorrupt) {
		float sortAmt = sort / 100.0;
		float shiftAmt = shift / 100.0;
		if (sortAmt > 0.0) {
			sampleUv = pixelSort(sampleUv, row, sortAmt, rt, seed, resX);
		}
		if (shiftAmt > 0.0) {
			sampleUv = byteShift(sampleUv, row, shiftAmt, rt, seed, resX);
		}
	}

	// Sample color from input.
	vec3 color = texture(inputTex, sampleUv).rgb;

	// Channel separation.
	if (channelShift > 0.0 && isCorrupt) {
		float chAmt = channelShift / 100.0;
		vec3 chHash = lineHash(row + 300.0, seed, rt);
		float rShift = (chHash.x - 0.5) * chAmt * 0.08;
		float bShift = (chHash.y - 0.5) * chAmt * 0.08;
		vec2 rUv = vec2(fract(sampleUv.x + rShift), sampleUv.y);
		vec2 bUv = vec2(fract(sampleUv.x + bShift), sampleUv.y);
		color.r = texture(inputTex, rUv).r;
		color.b = texture(inputTex, bUv).b;
	}

	// Bit corruption.
	if (bits > 0.0 && isCorrupt) {
		color = bitCorrupt(color, uv, row, bits / 100.0, rt, seed, resX);
	}

	frag = vec4(color, 1.0);
}

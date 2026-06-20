#version 450
// synth/perlin — ported PIXEL-IDENTICALLY from wgsl/perlin.wgsl (WGSL is canonical).
// Perlin-like gradient noise with quintic interpolation and optional domain warp.
// 2D mode uses time-animated gradient angles for a seamless loop; 3D mode samples a
// cross-section through a z-periodic 3D noise volume. Cross-checked against the
// bottom-left HLSL port (../noisemaker-hlsl/.../Effects/synth/Perlin.hlsl).
//
// No-layout effect (like solid.glsl / osc2d.glsl): the backend SYNTHESIZES the Params
// UBO and injects, after #version, `#define <name> data[slot].comp` for every engine
// global (resolution/time/aspectRatio/tileOffset/fullResolution/renderScale) AND every
// param uniform (scale/octaves/colorMode/ridges/warpIterations/warpScale/warpIntensity/
// seed/speed). We use the bare names directly and declare NO UBO and NO uniforms.
//
// DIMENSIONS is a compile-time integer #define injected by the runtime (globals
// .dimensions.define = "DIMENSIONS"; see perlin.json). Kept as a bare identifier
// (like NOISE_TYPE in noise.glsl); never declared or hardcoded. Picking 2D vs 3D at
// compile time lets the compiler dead-code-eliminate the unused implementation.
//
// Coordinate note (PORTING-GUIDE golden rule 1 & 3): the WGSL contains NO per-effect
// Y-flip, so there is nothing to drop. It divides st by fullResolution (BOTH axes via
// the res vector) then multiplies st.x by aspect — reproduced literally (the runtime
// applies the single global present flip). The `res` guard is computed exactly as the
// WGSL but st uses fullResolution regardless, matching the source.
//
// pcg/prng come from nm_core (the FOLD prng variant, bit-exact; divisor
// float(0xffffffffu) = 4294967295.0). hash3/grad3/quintic/smoothlerp/wrapZ/grid2D/
// noise2D/noise3D/fbm*/warpNoise*/domainWarp* are this effect's OWN helpers and are
// inlined verbatim under a perlin_ prefix (PORTING-GUIDE rule 2; avoids MSL keyword
// and symbol collisions). TAU/Z_PERIOD are local full-precision consts matching the
// WGSL literals exactly (nm_core's TAU is truncated). hash3 reads the bare `seed`.
//
// HAZARDS reproduced literally:
//   - hash3 cast: uvec3(ivec3(ps*1000.0) + 65536) — float->int TRUNCATION then
//     int->uint two's-complement reinterpret (NOT floatBitsToUint). Bit-sensitive.
//   - wrapZ uses WGSL float `%` (sign-of-dividend); GLSL `mod` is sign-of-divisor.
//     In the active param ranges z >= 0 (time>=0, speed>=0, channelOffset>=0) so the
//     two agree; we use GLSL mod (matches the HLSL nm_mod cross-check).
//   - Full 32-bit float throughout (PCG / hash3 bit-sensitive).
#include "include/nm_core.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Local full-precision TAU/Z_PERIOD exactly as the WGSL declares them (nm_core's TAU
// is truncated; a local name avoids the collision and preserves the extra digits).
const float PERLIN_TAU      = 6.283185307179586;
const float PERLIN_Z_PERIOD = 4.0;  // Period length in z-axis lattice units

// 3D hash using multiple rounds of mixing (perlin's own; NOT nm_core's). seed bare.
float perlin_hash3(vec3 p) {
	// Add seed to input to vary the noise pattern
	vec3 ps = p + float(seed) * 0.1;

	// Convert to unsigned integer values via large multipliers.
	// float->int truncation, +65536, then int->uint reinterpret (two's complement).
	uvec3 q = uvec3(ivec3(ps * 1000.0) + 65536);

	// Multiple rounds of mixing for thorough decorrelation
	q = q * 1664525u + 1013904223u;  // LCG constants
	q.x = q.x + q.y * q.z;
	q.y = q.y + q.z * q.x;
	q.z = q.z + q.x * q.y;

	q = q ^ (q >> uvec3(16u));

	q.x = q.x + q.y * q.z;
	q.y = q.y + q.z * q.x;
	q.z = q.z + q.x * q.y;

	return float(q.x ^ q.y ^ q.z) / 4294967295.0;
}

// Gradient from hash - returns normalized 3D vector.
vec3 perlin_grad3(vec3 p) {
	float h1 = perlin_hash3(p);
	float h2 = perlin_hash3(p + 127.1);
	float h3 = perlin_hash3(p + 269.5);

	// Generate independent gradient components - each component is [-1, 1]
	vec3 g = vec3(
		h1 * 2.0 - 1.0,
		h2 * 2.0 - 1.0,
		h3 * 2.0 - 1.0
	);

	return normalize(g);
}

// Quintic interpolation for smooth transitions.
float perlin_quintic(float t) {
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float perlin_smoothlerp(float x, float a, float b) {
	return a + perlin_quintic(x) * (b - a);
}

// Wrap z index for periodicity at lattice level. WGSL: z % Z_PERIOD; z>=0 in active
// domain so GLSL mod agrees (sign-of-divisor == sign-of-dividend here).
float perlin_wrapZ(float z) {
	return mod(z, PERLIN_Z_PERIOD);
}

// 2D periodic grid function - gradient angle animates with time.
float perlin_grid2D(vec2 st, vec2 cell, float timeAngle, float channelOffset) {
	float angle = prng(vec3(cell + float(seed), 1.0)).r * PERLIN_TAU;
	angle = angle + timeAngle + channelOffset * PERLIN_TAU;  // Animate gradient rotation
	vec2 gradient = vec2(cos(angle), sin(angle));
	vec2 dist = st - cell;
	return dot(gradient, dist);
}

// 2D periodic Perlin noise - time animates gradient angles for seamless loop.
float perlin_noise2D(vec2 st, float timeAngle, float channelOffset) {
	vec2 cell = floor(st);
	vec2 f = fract(st);

	float tl = perlin_grid2D(st, cell, timeAngle, channelOffset);
	float tr = perlin_grid2D(st, vec2(cell.x + 1.0, cell.y), timeAngle, channelOffset);
	float bl = perlin_grid2D(st, vec2(cell.x, cell.y + 1.0), timeAngle, channelOffset);
	float br = perlin_grid2D(st, cell + 1.0, timeAngle, channelOffset);

	float upper = perlin_smoothlerp(f.x, tl, tr);
	float lower = perlin_smoothlerp(f.x, bl, br);
	float val = perlin_smoothlerp(f.y, upper, lower);

	return val;  // Returns -1..1
}

// 3D gradient noise - Perlin-style with quintic interpolation.
// z-axis is periodic with period Z_PERIOD.
float perlin_noise3D(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);

	vec3 u = vec3(perlin_quintic(f.x), perlin_quintic(f.y), perlin_quintic(f.z));

	// Wrap z indices for periodicity - gradients at z=0 and z=Z_PERIOD will match
	float iz0 = perlin_wrapZ(i.z);
	float iz1 = perlin_wrapZ(i.z + 1.0);

	// 8 corners of 3D cube with wrapped z
	float n000 = dot(perlin_grad3(vec3(i.xy, iz0) + vec3(0.0, 0.0, 0.0)), f - vec3(0.0, 0.0, 0.0));
	float n100 = dot(perlin_grad3(vec3(i.xy, iz0) + vec3(1.0, 0.0, 0.0)), f - vec3(1.0, 0.0, 0.0));
	float n010 = dot(perlin_grad3(vec3(i.xy, iz0) + vec3(0.0, 1.0, 0.0)), f - vec3(0.0, 1.0, 0.0));
	float n110 = dot(perlin_grad3(vec3(i.xy, iz0) + vec3(1.0, 1.0, 0.0)), f - vec3(1.0, 1.0, 0.0));
	float n001 = dot(perlin_grad3(vec3(i.xy, iz1) + vec3(0.0, 0.0, 0.0)), f - vec3(0.0, 0.0, 1.0));
	float n101 = dot(perlin_grad3(vec3(i.xy, iz1) + vec3(1.0, 0.0, 0.0)), f - vec3(1.0, 0.0, 1.0));
	float n011 = dot(perlin_grad3(vec3(i.xy, iz1) + vec3(0.0, 1.0, 0.0)), f - vec3(0.0, 1.0, 1.0));
	float n111 = dot(perlin_grad3(vec3(i.xy, iz1) + vec3(1.0, 1.0, 0.0)), f - vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, u.x);
	float nx10 = mix(n010, n110, u.x);
	float nx01 = mix(n001, n101, u.x);
	float nx11 = mix(n011, n111, u.x);

	float nxy0 = mix(nx00, nx10, u.y);
	float nxy1 = mix(nx01, nx11, u.y);

	return mix(nxy0, nxy1, u.z);
}

// FBM for 2D periodic noise.
float perlin_fbm2D(vec2 st, float timeAngle, float channelOffset, int ridgedMode) {
	int MAX_OCT = 8;
	float amplitude = 0.5;
	float frequency = 1.0;
	float sum = 0.0;
	float maxVal = 0.0;
	int oct = int(octaves);
	if (oct < 1) { oct = 1; }

	for (int i = 0; i < MAX_OCT; i = i + 1) {
		if (i >= oct) { break; }
		float n = perlin_noise2D(st * frequency, timeAngle, channelOffset);  // -1..1
		n = clamp(n * 1.5, -1.0, 1.0);
		if (ridgedMode == 1) {
			n = 1.0 - abs(n);
		} else {
			n = (n + 1.0) * 0.5;
		}
		sum = sum + n * amplitude;
		maxVal = maxVal + amplitude;
		frequency = frequency * 2.0;
		amplitude = amplitude * 0.5;
	}
	return sum / maxVal;
}

// FBM using 3D noise with circular time for seamless looping.
// 2D cross-section moves through 3D noise as time varies.
float perlin_fbm3D(vec2 st, float timeAngle, float channelOffset, int ridgedMode) {
	int MAX_OCT = 8;
	float amplitude = 0.5;
	float frequency = 1.0;
	float sum = 0.0;
	float maxVal = 0.0;
	int oct = int(octaves);
	if (oct < 1) { oct = 1; }

	// Linear time traversal with periodic z-axis
	// time goes 0->1, map to 0->Z_PERIOD for one complete loop
	float z = timeAngle / PERLIN_TAU * PERLIN_Z_PERIOD + channelOffset;

	for (int i = 0; i < MAX_OCT; i = i + 1) {
		if (i >= oct) { break; }
		vec3 p = vec3(st * frequency, z);
		float n = perlin_noise3D(p);  // -1..1
		// Scale up by ~1.5 to spread the gaussian-ish distribution
		// Perlin noise rarely hits +-1, so this expands the usable range
		n = clamp(n * 1.5, -1.0, 1.0);
		if (ridgedMode == 1) {
			n = 1.0 - abs(n);  // fold at zero, gives 0..1 with ridges at zero-crossings
		} else {
			n = (n + 1.0) * 0.5;  // normalize to 0..1
		}
		sum = sum + n * amplitude;
		maxVal = maxVal + amplitude;
		frequency = frequency * 2.0;
		amplitude = amplitude * 0.5;
	}
	return sum / maxVal;
}

// Single-octave warp noise helpers (cheap, no fbm).
float perlin_warpNoise2D(vec2 p, float timeAngle) {
	return perlin_noise2D(p, timeAngle, 0.0);
}

float perlin_warpNoise3D(vec2 p, float z) {
	return perlin_noise3D(vec3(p, z));
}

// Domain warp: iteratively displace coordinates using noise.
vec2 perlin_domainWarp2D(vec2 st, float timeAngle, int iterations, float wScale, float wIntensity) {
	float wFreq = max(0.1, 100.0 / max(wScale, 0.01));
	float disp = wIntensity * 0.02;
	vec2 p = st;
	for (int i = 0; i < 4; i = i + 1) {
		if (i >= iterations) { break; }
		float fi = float(i);
		float nx = perlin_warpNoise2D(p * wFreq + vec2(fi * 5.2 + 1.7, fi * 1.3 + 13.7), timeAngle);
		float ny = perlin_warpNoise2D(p * wFreq + vec2(fi * 2.8 + 7.3, fi * 4.1 + 3.9), timeAngle);
		p = p + vec2(nx, ny) * disp;
	}
	return p;
}

vec2 perlin_domainWarp3D(vec2 st, float z, int iterations, float wScale, float wIntensity) {
	float wFreq = max(0.1, 100.0 / max(wScale, 0.01));
	float disp = wIntensity * 0.02;
	vec2 p = st;
	for (int i = 0; i < 4; i = i + 1) {
		if (i >= iterations) { break; }
		float fi = float(i);
		float nx = perlin_warpNoise3D(p * wFreq + vec2(fi * 5.2 + 1.7, fi * 1.3 + 13.7), z);
		float ny = perlin_warpNoise3D(p * wFreq + vec2(fi * 2.8 + 7.3, fi * 4.1 + 3.9), z);
		p = p + vec2(nx, ny) * disp;
	}
	return p;
}

void main() {
	vec2 res = resolution;
	if (res.x < 1.0) { res = vec2(1024.0, 1024.0); }
	// st divides by fullResolution (BOTH axes), NOT res — matches the WGSL literally;
	// `res` is computed for the guard but unused for st. Top-left port: NO Y-flip.
	vec2 st = (gl_FragCoord.xy + tileOffset) / fullResolution;
	// Center UVs so zoom scales from center, not corner
	st = st - 0.5;
	st.x = st.x * aspectRatio;
	// Invert scale to match vnoise convention: higher scale = fewer cells (zoomed in)
	float freq = max(0.1, 100.0 / max(scale, 0.01));
	st = st * freq;
	// Offset to keep noise coords positive (avoids hash artifacts at boundaries)
	st = st + 1000.0;

	// time is 0-1 representing position around circle for seamless looping
	// speed multiplies the time to control animation speed
	float timeAngle = time * speed * PERLIN_TAU;

	// Apply domain warp if enabled. Injected params arrive as float `#define`s
	// (data[slot].comp), so the integer-semantic ones are cast at the use site
	// (matching osc2d.glsl). DIMENSIONS is a true integer #define (globals
	// .dimensions.define) and is compared directly.
	int warpIters = int(warpIterations);
	int ridgedMode = int(ridges);
	if (warpIters > 0) {
		if (DIMENSIONS == 2) {
			st = perlin_domainWarp2D(st, timeAngle, warpIters, warpScale, warpIntensity);
		} else {
			float z = timeAngle / PERLIN_TAU * PERLIN_Z_PERIOD;
			st = perlin_domainWarp3D(st, z, warpIters, warpScale, warpIntensity);
		}
	}

	float r;
	float g;
	float b;

	if (DIMENSIONS == 2) {
		// 2D periodic noise (faster)
		r = perlin_fbm2D(st, timeAngle, 0.0, ridgedMode);
		g = perlin_fbm2D(st, timeAngle, 0.333, ridgedMode);
		b = perlin_fbm2D(st, timeAngle, 0.667, ridgedMode);
	} else {
		// 3D cross-section noise (original)
		r = perlin_fbm3D(st, timeAngle, 0.0, ridgedMode);
		g = perlin_fbm3D(st, timeAngle, 1.33, ridgedMode);
		b = perlin_fbm3D(st, timeAngle, 2.67, ridgedMode);
	}

	vec3 col;
	if (int(colorMode) == 0) {
		// Mono mode
		col = vec3(r);
	} else {
		// RGB mode
		col = vec3(r, g, b);
	}

	frag = vec4(col, 1.0);
}

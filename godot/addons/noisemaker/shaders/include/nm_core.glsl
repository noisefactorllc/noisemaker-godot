// nm_core.glsl — bit-exact shared primitives (reference/08), Vulkan GLSL 4.50.
// Ported from the reference WGSL; these are identical across all effects. Per-effect
// helpers (hsv/rgb, distance metrics, shape, smin, noise variants) are NOT here —
// each effect inlines its own (PORTING-GUIDE rule 2). Only pcg/prng/random and the
// truly-shared scalar helpers live here. Names match the WGSL so effect bodies port
// verbatim.
#ifndef NM_CORE_GLSL
#define NM_CORE_GLSL

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// Linear remap. (reference modulo() == GLSL built-in mod(): a - b*floor(a/b).)
float map(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// PCG 3D hash — byte-exact. Magic 1664525u/1013904223u, shift 16u, order-dependent.
uvec3 pcg(uvec3 v_in) {
	uvec3 v = v_in * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v = v ^ (v >> uvec3(16u));
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

// prng Variant A (with fold) — used by noise/gradient/cell/etc. Divisor is
// float(0xffffffffu) = 4294967295.0, NOT 2^32 (reference/08 H11).
vec3 prng(vec3 p0) {
	vec3 p = p0;
	p.x = (p.x >= 0.0) ? (p.x * 2.0) : (-p.x * 2.0 + 1.0);
	p.y = (p.y >= 0.0) ? (p.y * 2.0) : (-p.y * 2.0 + 1.0);
	p.z = (p.z >= 0.0) ? (p.z * 2.0) : (-p.z * 2.0 + 1.0);
	uvec3 u = pcg(uvec3(p));
	return vec3(u) / float(0xffffffffu);
}

float random(vec2 st) { return prng(vec3(st, 0.0)).x; }

float periodicFunction(float p) { return map(cos(p * TAU), -1.0, 1.0, 0.0, 1.0); }

int positiveModulo(int value, int modulus) {
	if (modulus == 0) { return 0; }
	int r = value % modulus;
	if (r < 0) { r = r + modulus; }
	return r;
}
#endif

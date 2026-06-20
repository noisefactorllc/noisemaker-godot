#version 450
// synth/osc2d — ported PIXEL-IDENTICALLY from wgsl/osc2d.wgsl. 2D oscillator
// pattern: a scalar value (0..1) is computed from phase = spatialPhase + timePhase
// along the (optionally rotated) y-axis, then written as grayscale. Seven shapes
// (sine, triangle, sawtooth, inverted sawtooth, square, noise1d scrolling, noise2d
// two-stage periodic).
//
// No-layout effect (like solid.glsl): the backend SYNTHESIZES the Params UBO and
// injects, after #version, `#define <name> data[slot].comp` for every engine global
// (resolution/time/aspectRatio/tileOffset/fullResolution/renderScale) AND every
// param uniform (oscType/frequency/speed/rotation/seed). So we use the bare names
// directly and declare NO UBO and NO uniforms.
//
// Coordinate note (PORTING-GUIDE golden rule 1): the WGSL bakes a Y-flip
// (res.y - position.y) to reconcile WebGPU's bottom-origin default framebuffer.
// gl_FragCoord here is top-left and the backend applies a single global flip at
// present, so we divide straight ((gl_FragCoord.xy + tileOffset) / res) with NO
// per-effect flip — matching the bottom-left HLSL disambiguator.
//
// osc2d's hash11/tilingNoise1D/periodicValue/rotate2D are this effect's OWN variants
// (NOT the shared nm_core ones) and are inlined verbatim per PORTING-GUIDE rule 2.
// WGSL `%` on f32 == GLSL `mod` (a - b*floor(a/b)), so the float-modulo wrap uses mod.
#include "include/nm_core.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Local full-precision PI/TAU exactly as the WGSL declares them (nm_core's PI/TAU
// are truncated; redeclaring them would also collide, so use local names).
const float OSC_PI  = 3.141592653589793;
const float OSC_TAU = 6.283185307179586;

// Simple 1D hash for noise (osc2d's own variant).
// WGSL: var pv = fract(p * 234.34 + s * 0.7183);
//       pv = pv + pv * (pv + 34.23);
//       return fract(pv * pv);
float osc_hash11(float p, float s) {
	float pv = fract(p * 234.34 + s * 0.7183);
	pv = pv + pv * (pv + 34.23);
	return fract(pv * pv);
}

// Value noise 1D - tiles at integer frequency boundaries.
float osc_tilingNoise1D(float x, float freq, float s) {
	// x is in [0, 1] range, scale by frequency
	float p = x * freq;
	float i = floor(p);
	float f = fract(p);
	f = f * f * (3.0 - 2.0 * f);  // smoothstep

	// Wrap indices for seamless tiling. WGSL `%` on f32 == GLSL mod.
	float i0 = mod(mod(i, freq) + freq, freq);
	float i1 = mod(mod(i + 1.0, freq) + freq, freq);

	float a = osc_hash11(i0, s);
	float b = osc_hash11(i1, s);

	return mix(a, b, f);
}

// Periodic value function: h/t Etienne Jacob.
// WGSL: return (sin((t - v) * TAU) + 1.0) * 0.5;
float osc_periodicValue(float t, float v) {
	return (sin((t - v) * OSC_TAU) + 1.0) * 0.5;
}

// Rotate 2D coordinates (osc2d's own variant).
vec2 osc_rotate2D(vec2 p, float angle) {
	float s = sin(angle);
	float c = cos(angle);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// All oscillator functions return 0->1->0 (or 0->1) over t = 0..1.
float osc_oscSine(float t) {
	// Use half-cycle sine: 0->1->0 over t=0..1
	return sin(fract(t) * OSC_PI);
}

float osc_oscLinear(float t) {
	// Triangle wave: 0->1->0 over t=0..1
	float tf = fract(t);
	return 1.0 - abs(tf * 2.0 - 1.0);
}

float osc_oscSawtooth(float t) {
	// Sawtooth: 0->1 over t=0..1
	return fract(t);
}

float osc_oscSawtoothInv(float t) {
	// Inverted sawtooth: 1->0 over t=0..1
	return 1.0 - fract(t);
}

float osc_oscSquare(float t) {
	// Square wave: 0 or 1
	return step(0.5, fract(t));
}

void main() {
	vec2 res = resolution;
	if (res.x < 1.0) { res = vec2(1024.0, 1024.0); }

	// Normalized coordinates. Top-left port: divide straight (no WGSL res.y flip).
	vec2 st = (gl_FragCoord.xy + tileOffset) / res;

	// Center for rotation
	st = st - 0.5;
	st.x = st.x * aspectRatio;

	// Apply rotation
	float rotRad = rotation * OSC_PI / 180.0;
	st = osc_rotate2D(st, rotRad);

	// Spatial position in [0, 1] for noise sampling
	float spatialPos = st.y + 0.5;
	float freq = float(frequency);

	// The oscillator value is based on position along y-axis.
	// frequency controls how many bands appear; speed controls animation rate.
	float spatialPhase = st.y * freq;
	float timePhase = time * speed;
	float t = spatialPhase + timePhase;

	int oscTypeI = int(oscType);
	float val;
	if (oscTypeI == 0) {
		// Sine
		val = osc_oscSine(t);
	} else if (oscTypeI == 1) {
		// Linear (triangle)
		val = osc_oscLinear(t);
	} else if (oscTypeI == 2) {
		// Sawtooth
		val = osc_oscSawtooth(t);
	} else if (oscTypeI == 3) {
		// Sawtooth inverted
		val = osc_oscSawtoothInv(t);
	} else if (oscTypeI == 4) {
		// Square
		val = osc_oscSquare(t);
	} else if (oscTypeI == 5) {
		// noise1d - scrolling version of noise2d.
		// At t=0 must match noise2d exactly, then scrolls the pattern over time.
		float scrollOffset = fract(time * speed);
		float scrolledPos = fract(spatialPos + scrollOffset);

		// Same computation as noise2d at t=0
		float timeNoise = osc_tilingNoise1D(scrolledPos, freq, float(seed) + 12345.0);
		float valueNoise = osc_tilingNoise1D(scrolledPos, freq, float(seed));
		float scaledTime = osc_periodicValue(0.0, timeNoise) * speed;
		val = osc_periodicValue(scaledTime, valueNoise);
	} else {
		// noise2d (oscType == 6) - two-stage periodic.
		// Python: scaled_time = periodic_value(time, time_noise) * speed
		//         result      = periodic_value(scaled_time, value_noise)
		float timeNoise = osc_tilingNoise1D(spatialPos, freq, float(seed) + 12345.0);
		float valueNoise = osc_tilingNoise1D(spatialPos, freq, float(seed));

		// Two-stage periodic: time -> periodic -> scale -> periodic
		float scaledTime = osc_periodicValue(time, timeNoise) * speed;
		val = osc_periodicValue(scaledTime, valueNoise);
	}

	frag = vec4(vec3(val), 1.0);
}

#version 450
// filter/warp — ported from wgsl/warp.wgsl (cross-checked against the golden-source
// glsl/warp.glsl). Perlin-noise domain warp: samples a 2D gradient-noise field on each
// axis, perturbs the UV, applies a wrap mode, then resamples the input (optional 4-tap
// screen-space antialiasing). Top-left origin (Godot/Vulkan) = WGSL @position — NO Y-flip.
//
// No-layout effect (effects/filter/warp.json has no uniformLayout): the backend
// synthesizes the Params UBO and injects `#define strength …`/`scale`/`seed`/`speed`/
// `wrap`/`antialias` plus engine globals (`time`), so bare reference names are used
// directly. Ints (seed/speed/wrap) and the bool (antialias) arrive as floats — cast with
// int(...) / compare > 0.5 to match the reference. Input texture bound at set 0, binding 1.
//
// SEED PATH CROSS-CHECK: the reference GLSL and WGSL AGREE on every noise/seed constant
// here — the seed enters additively as `noiseCoord + float(seed)` (and `+ 10.0` for the
// y axis), and grid() adds `time * TAU * float(speed)`. Unlike curl, warp has NO divergent
// seed-offset constant. prng's divisor is float(0xffffffffu) (matches GLSL float(uint(...))).
//
// pcg/prng are byte-identical to nm_core's (the GLSL's inline copies match exactly:
// prng Variant A sign-fold + pcg(uvec3) / float(0xffffffffu)), so they are reused. TAU
// uses the reference's literal 6.28318530718 (nm_core's TAU is identical to that value).
#include "include/nm_core.glsl"

layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float smootherstep(float x) {
	return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

float smoothlerp(float x, float a, float b) {
	return a + smootherstep(x) * (b - a);
}

// grid — gradient dot for one lattice cell. Gradient angle from prng(.r), rotated over
// time by speed. Verbatim from the reference (st/cell as in WGSL; uses bare time/speed).
float grid(vec2 st, vec2 cell) {
	float angle = prng(vec3(cell, 1.0)).r * TAU;
	angle += time * TAU * float(speed);
	vec2 gradient = vec2(cos(angle), sin(angle));
	vec2 dist = st - cell;
	return dot(gradient, dist);
}

// perlinNoise — gradient noise with smootherstep interpolation, remapped to [0,1].
float perlinNoise(vec2 st, vec2 noiseScale) {
	st *= noiseScale;
	vec2 cell = floor(st);
	float tl = grid(st, cell);
	float tr = grid(st, vec2(cell.x + 1.0, cell.y));
	float bl = grid(st, vec2(cell.x, cell.y + 1.0));
	float br = grid(st, cell + 1.0);
	float upper = smoothlerp(st.x - cell.x, tl, tr);
	float lower = smoothlerp(st.x - cell.x, bl, br);
	float val = smoothlerp(st.y - cell.y, upper, lower);
	return val * 0.5 + 0.5;
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	float ar = texSize.x / texSize.y;
	vec2 uv = gl_FragCoord.xy / texSize;

	// Perlin warp — sample both axes before applying either
	vec2 noiseCoord = uv * vec2(ar, 1.0);
	vec2 noiseScale = vec2(abs(scale * 3.0));
	float dx = (perlinNoise(noiseCoord + float(int(seed)), noiseScale) - 0.5) * strength * 0.01;
	float dy = (perlinNoise(noiseCoord + float(int(seed)) + 10.0, noiseScale) - 0.5) * strength * 0.01;
	uv.x += dx;
	uv.y += dy;

	// Apply wrap mode (0=mirror, 1=repeat, 2=clamp)
	int wrapMode = int(wrap);
	if (wrapMode == 0) {
		// mirror
		uv = abs(mod(uv + 1.0, 2.0) - 1.0);
	} else if (wrapMode == 1) {
		// repeat
		uv = mod(uv, 1.0);
	} else {
		// clamp
		uv = clamp(uv, 0.0, 1.0);
	}

	if (antialias > 0.5) {
		vec2 ddx = dFdx(uv);
		vec2 ddy = dFdy(uv);
		vec4 col = vec4(0.0);
		col += texture(inputTex, uv + ddx * -0.375 + ddy * -0.125);
		col += texture(inputTex, uv + ddx *  0.125 + ddy * -0.375);
		col += texture(inputTex, uv + ddx *  0.375 + ddy *  0.125);
		col += texture(inputTex, uv + ddx * -0.125 + ddy *  0.375);
		frag = col * 0.25;
	} else {
		frag = texture(inputTex, uv);
	}
}

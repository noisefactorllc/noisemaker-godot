#version 450
// filter/snow — ported PIXEL-IDENTICALLY from glsl/snow.glsl (the reference WGSL is a
// @compute shader writing a storage buffer; the validated WebGL2 GLSL is the fragment
// form, which is what this render pass mirrors). TV-static: animated hash noise blended
// into the source with a second "limiter" noise gating density. Single pass (progName
// "snow").
//
// No-layout effect (snow.json has no uniformLayout): the backend SYNTHESIZES the Params
// UBO and injects `#define <name> data[slot].comp` for the engine globals and every
// param uniform: alpha, pause, density. We use the bare names directly. Engine `time`
// used (bare). `pause` is a bool param arriving as float → tested `> 0.5` (matches the
// reference). Input texture at set 0, binding 1.
//
// ⚠️ RESERVED-NAME COLLISION: the reference helpers take a parameter literally named
// `time` (periodic_value(time, value), snow_noise(coord, time, ...)), which collides
// with the injected `#define time data[0].z` engine macro. Renamed the helper params to
// `timeArg` (pure symbol rename, no behavior change). The bare `time` remains only at
// the main() use site where the macro must resolve.
//
// COORDINATE NOTE: pixel coords come from gl_FragCoord.xy (top-left); the reference's
// `+ tileOffset` is a tiling concern we do not reproduce (tileOffset is (0,0) here).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float SNOW_TAU = 6.283185307179586;
const vec3 TIME_SEED_OFFSETS = vec3(97.0, 57.0, 131.0);
const vec3 STATIC_SEED = vec3(37.0, 17.0, 53.0);
const vec3 LIMITER_SEED = vec3(113.0, 71.0, 193.0);

float normalized_sine(float value) {
	return (sin(value) + 1.0) * 0.5;
}

float periodic_value(float timeArg, float value) {
	return normalized_sine((timeArg - value) * SNOW_TAU);
}

vec3 snow_fract_vec3(vec3 value) {
	return value - floor(value);
}

float snow_hash(vec3 input_sample) {
	vec3 scaled = snow_fract_vec3(input_sample * 0.1031);
	float dot_val = dot(scaled, scaled.yzx + vec3(33.33));
	vec3 shifted = scaled + dot_val;
	float combined = (shifted.x + shifted.y) * shifted.z;
	float fractional = combined - floor(combined);
	return clamp(fractional, 0.0, 1.0);
}

float snow_noise(vec2 coord, float timeArg, float speed, vec3 seed) {
	float angle = timeArg * SNOW_TAU;
	float z_base = cos(angle) * speed;
	vec3 base_sample = vec3(coord.x + seed.x, coord.y + seed.y, z_base + seed.z);
	float base_value = snow_hash(base_sample);

	if (speed == 0.0 || timeArg == 0.0) {
		return base_value;
	}

	vec3 time_seed = seed + TIME_SEED_OFFSETS;
	vec3 time_sample = vec3(
		coord.x + time_seed.x,
		coord.y + time_seed.y,
		1.0 + time_seed.z
	);
	float time_value = snow_hash(time_sample);
	float scaled_time = periodic_value(timeArg, time_value) * speed;
	float periodic = periodic_value(scaled_time, base_value);
	return clamp(periodic, 0.0, 1.0);
}

void main() {
	ivec2 coords = ivec2(int(gl_FragCoord.x), int(gl_FragCoord.y));
	vec4 texel = texelFetch(inputTex, coords, 0);

	float alphaVal = clamp(alpha, 0.0, 1.0);
	if (alphaVal == 0.0) {
		frag = texel;
		return;
	}

	vec2 pixelCoord = vec2(gl_FragCoord.x, gl_FragCoord.y);
	float timeVal = pause > 0.5 ? 0.0 : time;
	float speedVal = 100.0;

	float static_value = snow_noise(pixelCoord, timeVal, speedVal, STATIC_SEED);
	float limiter_value = snow_noise(pixelCoord, timeVal, speedVal, LIMITER_SEED);
	float d = max(density * 0.01, 0.0001);
	float exponent = (1.0 - d) / d;
	float limiter_mask = pow(min(limiter_value, 0.99), exponent) * alphaVal;

	vec3 static_color = vec3(static_value);
	vec3 mixed_rgb = mix(texel.xyz, static_color, vec3(limiter_mask));

	frag = vec4(mixed_rgb, texel.w);
}

#version 450
// filter/texture — ported PIXEL-IDENTICALLY from wgsl/texture.wgsl. Generates a height
// field from one of several texture modes (canvas/crosshatch/halftone/paper/stucco),
// derives shading from the gradient, then blends back into the source. Single render
// pass (progName "texture").
//
// No-layout effect (texture.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define <name> data[slot].comp` for the params alpha/scale and
// engine `time`. MODE is a COMPILE-TIME define (globals.mode.define = "MODE"), injected
// by the backend as `#define MODE <int>` from the graph pass `defines` — kept as a bare
// identifier so it constant-folds the 5-way height_field dispatch.
//
// RESERVED-NAME / BUILTIN NOTE: the WGSL helper `height_halftone` declares a local named
// `dot`, which would shadow the GLSL builtin dot() — renamed to `dotVal` (pure rename).
// `in.uv` (vertex-interpolated UV) → the fullscreen VS's v_uv (== screen UV in [0,1]).
// textureDimensions → textureSize cast to vec2. WGSL `bitcast<u32>(p.x)` where p.x is i32
// → GLSL `uint(p.x)` (a bit-preserving int→uint, NOT floatBitsToUint of a float).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float TX_PI = 3.14159265359;
const float INV_UINT32_MAX = 1.0 / 4294967295.0;
const int Z_LOOP = 2;
const float SHADE_GAIN = 4.4;

float clamp01(float value) {
	return clamp(value, 0.0, 1.0);
}

float fade(float t) {
	return t * t * (3.0 - 2.0 * t);
}

vec2 freq_for_shape(float base_freq, vec2 dims) {
	float w = max(dims.x, 1.0);
	float h = max(dims.y, 1.0);
	if (abs(w - h) < 0.5) {
		return vec2(base_freq, base_freq);
	}
	if (w > h) {
		return vec2(base_freq, base_freq * w / h);
	}
	return vec2(base_freq * h / w, base_freq);
}

uint hash_uint(uint x_in) {
	uint x = x_in;
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

float fast_hash(ivec3 p, uint salt) {
	uint h = salt ^ 0x9e3779b9u;
	h ^= uint(p.x) * 0x27d4eb2du;
	h = hash_uint(h);
	h ^= uint(p.y) * 0xc2b2ae35u;
	h = hash_uint(h);
	h ^= uint(p.z) * 0x165667b1u;
	h = hash_uint(h);
	return float(h) * INV_UINT32_MAX;
}

float value_noise(vec2 uv, vec2 freq, float motion, uint salt) {
	vec2 scaled_uv = uv * max(freq, vec2(1.0, 1.0));
	vec2 cell_floor = floor(scaled_uv);
	vec2 frac_part = fract(scaled_uv);
	ivec2 base_cell = ivec2(int(cell_floor.x), int(cell_floor.y));

	float z_floor = floor(motion);
	float z_frac = fract(motion);
	int z0 = int(z_floor) % Z_LOOP;
	int z1 = (z0 + 1) % Z_LOOP;

	float c000 = fast_hash(ivec3(base_cell.x + 0, base_cell.y + 0, z0), salt);
	float c100 = fast_hash(ivec3(base_cell.x + 1, base_cell.y + 0, z0), salt);
	float c010 = fast_hash(ivec3(base_cell.x + 0, base_cell.y + 1, z0), salt);
	float c110 = fast_hash(ivec3(base_cell.x + 1, base_cell.y + 1, z0), salt);
	float c001 = fast_hash(ivec3(base_cell.x + 0, base_cell.y + 0, z1), salt);
	float c101 = fast_hash(ivec3(base_cell.x + 1, base_cell.y + 0, z1), salt);
	float c011 = fast_hash(ivec3(base_cell.x + 0, base_cell.y + 1, z1), salt);
	float c111 = fast_hash(ivec3(base_cell.x + 1, base_cell.y + 1, z1), salt);

	float tx = fade(frac_part.x);
	float ty = fade(frac_part.y);
	float tz = fade(z_frac);

	float x00 = mix(c000, c100, tx);
	float x10 = mix(c010, c110, tx);
	float x01 = mix(c001, c101, tx);
	float x11 = mix(c011, c111, tx);

	float y0 = mix(x00, x10, ty);
	float y1 = mix(x01, x11, ty);

	return mix(y0, y1, tz);
}

// Paper: 3-octave ridged noise (original texture)
float height_paper(vec2 uv, vec2 base_freq, float motion) {
	vec2 freq = max(base_freq, vec2(1.0, 1.0));
	float amplitude = 0.5;
	float accum = 0.0;
	float total = 0.0;

	for (uint octave = 0u; octave < 3u; octave = octave + 1u) {
		uint salt = 0x9e3779b9u * (octave + 1u);
		float sample_val = value_noise(uv, freq, motion + float(octave) * 0.37, salt);
		float ridged = 1.0 - abs(sample_val * 2.0 - 1.0);
		accum = accum + ridged * amplitude;
		total = total + amplitude;
		freq = freq * 2.0;
		amplitude = amplitude * 0.55;
	}

	if (total <= 0.0) { return clamp01(accum); }
	return clamp01(accum / total);
}

// Stucco: 2-octave smooth noise, lower frequency, rounder bumps
float height_stucco(vec2 uv, vec2 base_freq, float motion) {
	vec2 freq = max(base_freq, vec2(1.0, 1.0));
	float amplitude = 0.5;
	float accum = 0.0;
	float total = 0.0;

	for (uint octave = 0u; octave < 2u; octave = octave + 1u) {
		uint salt = 0x9e3779b9u * (octave + 1u);
		float sample_val = value_noise(uv, freq, motion + float(octave) * 0.37, salt);
		accum = accum + sample_val * amplitude;
		total = total + amplitude;
		freq = freq * 2.0;
		amplitude = amplitude * 0.5;
	}

	if (total <= 0.0) { return clamp01(accum); }
	return clamp01(accum / total);
}

// Canvas: woven fabric pattern with slight noise perturbation
float height_canvas(vec2 uv, vec2 base_freq, float motion) {
	vec2 st = uv * base_freq;
	float warpX = abs(sin(st.x * TX_PI));
	float weftY = abs(sin(st.y * TX_PI));
	float weave = warpX * weftY;

	float noise = value_noise(uv, base_freq * 0.5, motion, 0x12345678u);
	return clamp01(weave * 0.85 + noise * 0.15);
}

// Halftone: regular circular dot grid
float height_halftone(vec2 uv, vec2 base_freq) {
	vec2 st = uv * base_freq;
	vec2 cell = fract(st) - 0.5;
	float dotVal = 1.0 - clamp01(length(cell) * 3.0);
	return dotVal * dotVal;
}

// Crosshatch: two overlapping diagonal sine ridges
float height_crosshatch(vec2 uv, vec2 base_freq) {
	vec2 st = uv * base_freq;
	float d1 = abs(sin((st.x + st.y) * TX_PI));
	float d2 = abs(sin((st.x - st.y) * TX_PI));
	return clamp01(d1 * d2);
}

// Dispatch to the active mode's height function — single variant selected
// at compile time by the MODE const (glslang constant-folds).
float height_field(vec2 uv, vec2 base_freq, float motion) {
	if (MODE == 0) { return height_canvas(uv, base_freq, motion); }
	if (MODE == 1) { return height_crosshatch(uv, base_freq); }
	if (MODE == 2) { return height_halftone(uv, base_freq); }
	if (MODE == 4) { return height_stucco(uv, base_freq, motion); }
	return height_paper(uv, base_freq, motion);  // 3 = paper (default)
}

void main() {
	vec4 base_color = texture(inputTex, v_uv);
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 pixel_step = 1.0 / dims;

	float a = clamp(alpha, 0.0, 1.0);
	if (a <= 0.0) {
		frag = base_color;
		return;
	}

	// Paper and stucco use different base frequencies
	float freq_scale = 24.0;
	if (MODE == 4) { freq_scale = 48.0; }
	vec2 base_freq = freq_for_shape(freq_scale * (10.01 - scale), dims);
	float motion = time * float(Z_LOOP);

	// Sample height field at center and 4 neighbors for gradient
	float h_center = height_field(v_uv, base_freq, motion);
	float h_right = height_field(v_uv + vec2(pixel_step.x, 0.0), base_freq, motion);
	float h_left = height_field(v_uv - vec2(pixel_step.x, 0.0), base_freq, motion);
	float h_up = height_field(v_uv + vec2(0.0, pixel_step.y), base_freq, motion);
	float h_down = height_field(v_uv - vec2(0.0, pixel_step.y), base_freq, motion);

	float gx = h_right - h_left;
	float gy = h_down - h_up;
	float gradient = sqrt(gx * gx + gy * gy);

	// Stucco uses stronger shading for more pronounced bumps
	float gain = SHADE_GAIN * 0.25;
	if (MODE == 4) { gain = SHADE_GAIN * 0.5; }
	float shade_base = clamp01(gradient * gain);

	float highlight_mix = clamp01((shade_base * shade_base) * 1.25);
	float base_factor = 0.9 + h_center * 0.35;
	float factor = clamp(base_factor + highlight_mix * 0.35, 0.85, 1.6);

	vec3 scaled_rgb = clamp(base_color.xyz * factor, vec3(0.0), vec3(1.0));

	frag = vec4(mix(base_color.xyz, scaled_rgb, a), base_color.w);
}

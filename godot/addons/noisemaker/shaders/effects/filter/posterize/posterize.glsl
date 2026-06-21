#version 450
// filter/posterize — ported PIXEL-IDENTICALLY from wgsl/posterize.wgsl.
// sRGB-aware color quantization with adjustable gamma. Single render pass:
//   1. sRGB->linear the input rgb.
//   2. Apply forward gamma (pow with gamma_value).
//   3. Quantize into `levels` bins (centered via half_step), with optional
//      derivative-based edge antialias (fwidth + smoothstep).
//   4. Apply inverse gamma, linear->sRGB, clamp01. Alpha passes through.
//
// No-layout effect: the backend synthesizes the Params UBO and injects, after
// #version, `#define <name> data[slot].comp` for every engine global and every
// param uniform (levels/gamma/antialias). So we use the bare names directly and
// declare NO UBO and NO uniforms. The input texture is bound at set 0, binding 1
// (pass.inputs order). No shared nm_core primitives are used (no PCG/prng/mod),
// so nm_core.glsl is NOT included.
//
// COORDINATE NOTE: this is a filter — WGSL samples uv = pos.xy / textureDimensions
// (inputTex, 0), i.e. divides by the INPUT TEXTURE size, NOT fullResolution. We use
// textureSize(inputTex, 0). gl_FragCoord is top-left (matches WGSL); NO Y-flip.
//
// TRANSLATION HAZARDS:
//  * `antialias` is an i32 uniform in WGSL tested `!= 0`. It arrives here as a float
//    #define (boolean param), so we test `!= 0.0` to mirror the WGSL form.
//  * `levels`/`gamma` arrive as float #defines (int / float params); max()/round()
//    reproduce the WGSL float math exactly.
//  * pow_vec3 uses vec3(exponent). sRGB transfer constants kept literal.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float MIN_LEVELS = 1.0;
const float MIN_GAMMA = 1e-3;

// clamp_01(value) — verbatim WGSL.
float clamp_01(float value) {
	return clamp(value, 0.0, 1.0);
}

// srgb_to_linear_component(value) — verbatim WGSL.
float srgb_to_linear_component(float value) {
	if (value <= 0.04045) {
		return value / 12.92;
	}
	return pow((value + 0.055) / 1.055, 2.4);
}

// linear_to_srgb_component(value) — verbatim WGSL.
float linear_to_srgb_component(float value) {
	if (value <= 0.0031308) {
		return value * 12.92;
	}
	return 1.055 * pow(value, 1.0 / 2.4) - 0.055;
}

// srgb_to_linear_rgb(rgb) — verbatim WGSL (per-component).
vec3 srgb_to_linear_rgb(vec3 rgb) {
	return vec3(
		srgb_to_linear_component(rgb.x),
		srgb_to_linear_component(rgb.y),
		srgb_to_linear_component(rgb.z)
	);
}

// linear_to_srgb_rgb(rgb) — verbatim WGSL (per-component).
vec3 linear_to_srgb_rgb(vec3 rgb) {
	return vec3(
		linear_to_srgb_component(rgb.x),
		linear_to_srgb_component(rgb.y),
		linear_to_srgb_component(rgb.z)
	);
}

// pow_vec3(value, exponent) — verbatim WGSL.
vec3 pow_vec3(vec3 value, float exponent) {
	return pow(value, vec3(exponent));
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 texel = texture(inputTex, uv);

	float levels_raw = max(levels, 0.0);
	float levels_quantized = max(round(levels_raw), MIN_LEVELS);
	if (levels_quantized <= 1.0) {
		frag = texel;
		return;
	}

	float level_factor = levels_quantized;
	float inv_factor = 1.0 / level_factor;
	float half_step = inv_factor * 0.5;
	float gamma_value = max(gamma, MIN_GAMMA);
	float inv_gamma = 1.0 / gamma_value;

	vec3 working_rgb = srgb_to_linear_rgb(texel.xyz);
	working_rgb = pow_vec3(clamp(working_rgb, vec3(0.0), vec3(1.0)), gamma_value);

	// Posterize with optional edge smoothing
	vec3 scaled = working_rgb * level_factor + vec3(half_step);
	vec3 quantized_rgb;
	if (antialias != 0.0) {
		vec3 f = fract(scaled);
		vec3 fw = fwidth(scaled);
		vec3 blend = smoothstep(0.5 - fw * 0.5, 0.5 + fw * 0.5, f);
		quantized_rgb = (floor(scaled) + blend) * inv_factor;
	} else {
		quantized_rgb = floor(scaled) * inv_factor;
	}
	quantized_rgb = pow_vec3(clamp(quantized_rgb, vec3(0.0), vec3(1.0)), inv_gamma);

	quantized_rgb = linear_to_srgb_rgb(quantized_rgb);

	frag = vec4(
		clamp_01(quantized_rgb.x),
		clamp_01(quantized_rgb.y),
		clamp_01(quantized_rgb.z),
		texel.w
	);
}

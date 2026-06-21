#version 450
// filter/celShading program "celShadingColor" — ported from
// wgsl/celShadingColor.wgsl. sRGB-aware color quantization with diffuse shading.
// Pass 1 of 3: inputTex -> celShadingColorTex.
//
// No-layout effect (globals carry params): backend injects the Params UBO +
// `#define mixAmount …`/`levels …`/`gamma …`/`antialias …`/… and engine globals.
// Input texture bound at set 0, binding 1 (pass.inputs order: inputTex).
//
// PORTING NOTES:
//  * Ported from WGSL (top-left, canonical) — NO per-effect Y flip.
//  * uv = gl_FragCoord.xy / textureSize(inputTex, 0) — fragCoord divided by the
//    SAMPLED texture's own size (WGSL adds no tileOffset / fullResolution).
//  * Helpers (srgb<->linear, pow_vec3) are this effect's OWN copies, inlined
//    verbatim — NOT the shared primitives.
//  * `levels` is an int param: WGSL `f32(uniforms.levels)` -> `float(levels)`.
//  * `antialias` is a boolean param (injected as 0.0/1.0): WGSL tests `!= 0`.
//    Reproduced as `int(antialias) != 0`.
//  * fwidth used only in the antialias branch, mirroring the WGSL.
//  * Arithmetic reproduced literally (no reassociation); full f32.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float MIN_GAMMA = 1e-3;

// srgb_to_linear_component — VERBATIM from celShadingColor.wgsl. Per-effect copy.
float srgb_to_linear_component(float value) {
	if (value <= 0.04045) {
		return value / 12.92;
	}
	return pow((value + 0.055) / 1.055, 2.4);
}

// linear_to_srgb_component — VERBATIM from celShadingColor.wgsl. Per-effect copy.
float linear_to_srgb_component(float value) {
	if (value <= 0.0031308) {
		return value * 12.92;
	}
	return 1.055 * pow(value, 1.0 / 2.4) - 0.055;
}

// srgb_to_linear_rgb — VERBATIM from celShadingColor.wgsl. Per-effect copy.
vec3 srgb_to_linear_rgb(vec3 rgb) {
	return vec3(
		srgb_to_linear_component(rgb.x),
		srgb_to_linear_component(rgb.y),
		srgb_to_linear_component(rgb.z)
	);
}

// linear_to_srgb_rgb — VERBATIM from celShadingColor.wgsl. Per-effect copy.
vec3 linear_to_srgb_rgb(vec3 rgb) {
	return vec3(
		linear_to_srgb_component(rgb.x),
		linear_to_srgb_component(rgb.y),
		linear_to_srgb_component(rgb.z)
	);
}

// pow_vec3 — VERBATIM from celShadingColor.wgsl. Per-effect copy.
vec3 pow_vec3(vec3 value, float exponent) {
	return vec3(
		pow(value.x, exponent),
		pow(value.y, exponent),
		pow(value.z, exponent)
	);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	vec4 origColor = texture(inputTex, uv);
	float lev = float(levels);

	// Apply diffuse shading based on light direction
	vec3 lightDir = normalize(lightDirection);
	float gradientShade = dot(normalize(vec3(uv - 0.5, 0.5)), lightDir);
	float diffuse = 0.5 + 0.5 * gradientShade;
	float shadeFactor = mix(1.0, 0.5 + 0.5 * diffuse, strength);
	vec3 shadedColor = origColor.rgb * shadeFactor;

	// sRGB-aware quantization
	float gamma_value = max(gamma, MIN_GAMMA);
	float inv_gamma = 1.0 / gamma_value;
	float inv_factor = 1.0 / lev;
	float half_step = inv_factor * 0.5;

	vec3 working_rgb = srgb_to_linear_rgb(shadedColor);
	working_rgb = pow_vec3(clamp(working_rgb, vec3(0.0), vec3(1.0)), gamma_value);

	// Posterize with optional edge smoothing
	vec3 scaled = working_rgb * lev + vec3(half_step);
	vec3 quantized_rgb;
	if (int(antialias) != 0) {
		vec3 f = fract(scaled);
		vec3 fw = fwidth(scaled);
		vec3 blend = smoothstep(0.5 - fw * 0.5, 0.5 + fw * 0.5, f);
		quantized_rgb = (floor(scaled) + blend) * inv_factor;
	} else {
		quantized_rgb = floor(scaled) * inv_factor;
	}
	quantized_rgb = pow_vec3(clamp(quantized_rgb, vec3(0.0), vec3(1.0)), inv_gamma);
	quantized_rgb = linear_to_srgb_rgb(quantized_rgb);

	frag = vec4(clamp(quantized_rgb, vec3(0.0), vec3(1.0)), origColor.a);
}

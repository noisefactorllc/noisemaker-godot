#version 450
// filter/reindex program "nmReindexApply" — remap each pixel by its normalized OKLab-L
// lightness scaled by displacement, sampling the input at the wrapped offset index.
//
// WGSL-vs-GLSL DIVERGENCE in the wrap (GLSL wins — the WebGL2 golden runs the GLSL): the
// canonical wgsl/nmReindexApply.wgsl wraps via wrap_index = clamp(floor(value - dim*floor(
// value/dim)), 0, dim-1). The reference glsl/nmReindexApply.glsl instead wraps via
// int(fract(value/dim) * dim) then min(.., dim-1) — its own comment says this is "smooth
// wrapping to avoid seams at tile boundaries". These are ALGORITHMICALLY different at the
// fractional boundary, so to match the golden pixel-for-pixel we port the GLSL form.
// The value_map / oklab helpers are byte-identical between the WGSL and GLSL.
//
// No-layout effect: backend synthesizes the Params UBO + `#define uDisplacement
// data[3].x` (reindex.json global key `displacement`, uniform alias `uDisplacement`; this
// apply pass wires uniforms.uDisplacement = displacement). Use the bare name `uDisplacement`
// (the WGSL's binding name). Two inputs in pass.inputs order: inputTex (binding 1),
// statsTex (= global_stats, binding 2).
//
// COORDINATE NOTE: gl_FragCoord top-left, NO Y-flip; NO tileOffset/resolution remap (the
// reference GLSL declares those uniforms but never uses them in the math). textureLoad ->
// texelFetch; textureDimensions -> textureSize. WGSL `select(-1,1,c)` -> `c ? 1 : -1`.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D statsTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float clamp01(float value) {
	return clamp(value, 0.0, 1.0);
}

float srgb_to_linear(float value) {
	if (value <= 0.04045) {
		return value / 12.92;
	}
	return pow((value + 0.055) / 1.055, 2.4);
}

float cube_root(float value) {
	if (value == 0.0) {
		return 0.0;
	}
	float sign_value = value >= 0.0 ? 1.0 : -1.0;
	return sign_value * pow(abs(value), 1.0 / 3.0);
}

float oklab_l_component(vec3 rgb) {
	float r_lin = srgb_to_linear(clamp01(rgb.x));
	float g_lin = srgb_to_linear(clamp01(rgb.y));
	float b_lin = srgb_to_linear(clamp01(rgb.z));

	float l = 0.4121656120 * r_lin + 0.5362752080 * g_lin + 0.0514575653 * b_lin;
	float m = 0.2118591070 * r_lin + 0.6807189584 * g_lin + 0.1074065790 * b_lin;
	float s = 0.0883097947 * r_lin + 0.2818474174 * g_lin + 0.6302613616 * b_lin;

	float l_c = cube_root(l);
	float m_c = cube_root(m);
	float s_c = cube_root(s);

	float lightness = 0.2104542553 * l_c + 0.7936177850 * m_c - 0.0040720468 * s_c;
	return clamp01(lightness);
}

float value_map_component(vec4 texel) {
	return oklab_l_component(texel.xyz);
}

void main() {
	ivec2 texSize = textureSize(inputTex, 0);
	ivec2 pixel = ivec2(gl_FragCoord.xy);

	if (pixel.x >= texSize.x || pixel.y >= texSize.y) {
		frag = vec4(0.0);
		return;
	}

	vec4 texel = texelFetch(inputTex, pixel, 0);
	float referenceValue = value_map_component(texel);

	vec2 minMax = texelFetch(statsTex, ivec2(0, 0), 0).xy;
	float range = minMax.y - minMax.x;

	float normalized = referenceValue;
	if (range > 0.0001) {
		normalized = clamp01((referenceValue - minMax.x) / range);
	}

	float modRange = float(min(texSize.x, texSize.y));
	float offsetValue = normalized * uDisplacement * modRange + normalized;

	// Use fract() for smooth wrapping to avoid seams at tile boundaries
	int sampleX = int(fract(offsetValue / float(texSize.x)) * float(texSize.x));
	int sampleY = int(fract(offsetValue / float(texSize.y)) * float(texSize.y));

	// Clamp to valid texture coordinates
	sampleX = min(sampleX, texSize.x - 1);
	sampleY = min(sampleY, texSize.y - 1);

	frag = texelFetch(inputTex, ivec2(sampleX, sampleY), 0);
}

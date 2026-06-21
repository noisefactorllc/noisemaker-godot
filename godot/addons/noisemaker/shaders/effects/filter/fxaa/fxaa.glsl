#version 450
// filter/fxaa — ported PIXEL-IDENTICALLY from wgsl/fxaa.wgsl. Edge-aware blur of the
// center texel with its 4 neighbors, weighted by an exp() of luminance difference,
// gated by a contrast threshold, then blended by strength. Alpha preserved. Single
// render pass (progName "fxaa").
//
// No-layout effect (fxaa.json has no uniformLayout): the backend SYNTHESIZES the Params
// UBO and injects `#define <name> data[slot].comp` for the engine globals and every
// param uniform: strength, sharpness, threshold. We use the bare names directly. Input
// texture at set 0, binding 1.
//
// ⚠️ RESERVED-NAME COLLISION: the WGSL helper weight_from_luma takes a parameter named
// `sharpness`, colliding with the injected `#define sharpness data[slot].comp` macro.
// Renamed the helper param to `sharp` (pure symbol rename). The bare `sharpness`
// remains only at the main() call sites where the macro must resolve.
//
// NOTE: ported from the WGSL (always-RGBA luminance path), NOT the GLSL — the reference
// GLSL carries dead channelCount<=2 branches (channelCount is hard-coded 4). Pixel
// coords from gl_FragCoord (top-left); WGSL `textureLoad` → GLSL `texelFetch`. No
// arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float FXAA_EPSILON = 1e-10;
const vec3 LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);

float luminance_from_rgb(vec3 rgb) {
	return dot(rgb, LUMA_WEIGHTS);
}

float weight_from_luma(float center_luma, float neighbor_luma, float sharp) {
	return exp(-sharp * abs(center_luma - neighbor_luma));
}

int reflect_coord(int coord, int limit) {
	if (limit <= 1) {
		return 0;
	}

	int period = 2 * limit - 2;
	int wrapped = coord % period;
	if (wrapped < 0) {
		wrapped = wrapped + period;
	}

	if (wrapped < limit) {
		return wrapped;
	}

	return period - wrapped;
}

vec4 load_texel(ivec2 coord, ivec2 size) {
	int rx = reflect_coord(coord.x, size.x);
	int ry = reflect_coord(coord.y, size.y);
	return texelFetch(inputTex, ivec2(rx, ry), 0);
}

void main() {
	ivec2 size = textureSize(inputTex, 0);
	ivec2 pixel_coord = ivec2(int(gl_FragCoord.x), int(gl_FragCoord.y));

	vec4 center_texel = load_texel(pixel_coord, size);
	vec4 north_texel = load_texel(pixel_coord + ivec2(0, -1), size);
	vec4 south_texel = load_texel(pixel_coord + ivec2(0, 1), size);
	vec4 west_texel = load_texel(pixel_coord + ivec2(-1, 0), size);
	vec4 east_texel = load_texel(pixel_coord + ivec2(1, 0), size);

	vec3 center_rgb = center_texel.xyz;
	vec3 north_rgb = north_texel.xyz;
	vec3 south_rgb = south_texel.xyz;
	vec3 west_rgb = west_texel.xyz;
	vec3 east_rgb = east_texel.xyz;

	float center_luma = luminance_from_rgb(center_rgb);
	float north_luma = luminance_from_rgb(north_rgb);
	float south_luma = luminance_from_rgb(south_rgb);
	float west_luma = luminance_from_rgb(west_rgb);
	float east_luma = luminance_from_rgb(east_rgb);

	// Threshold: skip AA when max luma contrast is below threshold.
	float maxDiff = max(
		max(abs(center_luma - north_luma), abs(center_luma - south_luma)),
		max(abs(center_luma - west_luma), abs(center_luma - east_luma))
	);
	if (maxDiff < threshold) {
		frag = center_texel;
		return;
	}

	float weight_center = 1.0;
	float weight_north = weight_from_luma(center_luma, north_luma, sharpness);
	float weight_south = weight_from_luma(center_luma, south_luma, sharpness);
	float weight_west = weight_from_luma(center_luma, west_luma, sharpness);
	float weight_east = weight_from_luma(center_luma, east_luma, sharpness);
	float weight_sum = weight_center + weight_north + weight_south + weight_west + weight_east + FXAA_EPSILON;

	vec3 blended_rgb = (
		center_rgb * weight_center
		+ north_rgb * weight_north
		+ south_rgb * weight_south
		+ west_rgb * weight_west
		+ east_rgb * weight_east
	) / weight_sum;

	vec4 result_texel = vec4(blended_rgb, center_texel.w);

	// Strength: blend between original and AA result.
	frag = mix(center_texel, result_texel, strength);
}

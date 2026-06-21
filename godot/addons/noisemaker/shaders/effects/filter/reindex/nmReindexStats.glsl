#version 450
// filter/reindex program "nmReindexStats" — ported PIXEL-IDENTICALLY from
// wgsl/nmReindexStats.wgsl (cross-checked against glsl/nmReindexStats.glsl — they agree).
// Reindex pass 1: compute the per-8x8-tile min/max OKLab-L lightness. Only the tile-anchor
// texel (local 0,0) does the reduction; other texels emit 0.
//
// No-layout effect (reindex.json: only param is `uDisplacement`, used solely by the apply
// pass; this pass references no params). Backend synthesizes the Params UBO (engine globals
// + uDisplacement) but this shader uses none of them. Single input `inputTex` at set 0,
// binding 1.
//
// COORDINATE NOTE: ported from WGSL (top-left). fragCoord = ivec2(gl_FragCoord.xy). NO
// Y-flip. WGSL `select(-1.0, 1.0, value >= 0.0)` -> `value >= 0.0 ? 1.0 : -1.0` (operands
// reversed). textureLoad -> texelFetch; textureDimensions -> textureSize. The WGSL's early
// guards on dims==0 / negative coord are unreachable on a valid full-res draw and are
// folded into the tile-anchor check; the reference GLSL drops them identically.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float F32_MAX = 3.402823466e38;
const float F32_MIN = -3.402823466e38;
const int TILE_SIZE = 8;

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
	ivec2 coord = ivec2(gl_FragCoord.xy);

	int local_x = coord.x % TILE_SIZE;
	int local_y = coord.y % TILE_SIZE;
	if (local_x != 0 || local_y != 0) {
		frag = vec4(0.0);
		return;
	}

	ivec2 dims = textureSize(inputTex, 0);
	int width = dims.x;
	int height = dims.y;

	float min_value = F32_MAX;
	float max_value = F32_MIN;
	ivec2 tile_origin = coord;

	for (int oy = 0; oy < TILE_SIZE; oy = oy + 1) {
		int py = tile_origin.y + oy;
		if (py >= height) {
			break;
		}
		for (int ox = 0; ox < TILE_SIZE; ox = ox + 1) {
			int px = tile_origin.x + ox;
			if (px >= width) {
				break;
			}
			vec4 sample0 = texelFetch(inputTex, ivec2(px, py), 0);
			float value = value_map_component(sample0);
			min_value = min(min_value, value);
			max_value = max(max_value, value);
		}
	}

	frag = vec4(min_value, max_value, 0.0, 1.0);
}

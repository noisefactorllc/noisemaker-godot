#version 450
// filter/normalize program "apply" — ported PIXEL-IDENTICALLY from wgsl/apply.wgsl.
// GPGPU pass 4: apply normalization using the computed 1x1 min/max stats. Reads the stats
// texel at (0,0); remaps RGB to [0,1] over the global range, preserving alpha.
//
// No-layout effect (normalize.json globals == {}): backend synthesizes the Params UBO
// (engine globals only; none referenced here). Two inputs in pass.inputs order:
// inputTex = original image (binding 1), statsTex = 1x1 min/max (binding 2).
//
// COORDINATE NOTE: ported from WGSL (top-left). coord = ivec2(gl_FragCoord.xy). NO Y-flip;
// NO globalCoord/tileOffset remap (the WGSL has none — the reference GLSL computes an
// unused globalCoord; we drop it). textureLoad -> texelFetch.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D statsTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 coord = ivec2(gl_FragCoord.xy);

	// Read global min/max from 1x1 stats texture
	vec4 stats = texelFetch(statsTex, ivec2(0, 0), 0);
	float global_min = stats.r;
	float global_max = stats.g;
	float range = global_max - global_min;

	// Read input pixel
	vec4 texel = texelFetch(inputTex, coord, 0);

	// Normalize RGB channels, preserve alpha
	vec4 normalized;
	if (range > 0.0001) {
		normalized = vec4(
			(texel.r - global_min) / range,
			(texel.g - global_min) / range,
			(texel.b - global_min) / range,
			texel.a
		);
	} else {
		// Avoid division by zero
		normalized = texel;
	}

	frag = normalized;
}

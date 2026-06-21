#version 450
// filter/reindex program "nmReindexReduce" — reduce per-tile stats to a single global
// min/max pair. Only fragment (0,0) does the reduction; others emit 0.
//
// WGSL-vs-GLSL DIVERGENCE (GLSL wins — the WebGL2 golden runs the GLSL): the canonical
// wgsl/nmReindexReduce.wgsl derives the tile grid from a `resolution` uniform that the
// effect definition does NOT wire to this pass (reindex.json's reduce pass lists only
// `statsTex`, no `uniforms`). The reference glsl/nmReindexReduce.glsl instead derives the
// tile count straight from `textureSize(statsTex)` (the stats texture is full input
// resolution: reindex.json `statsTiles` declares only a format, so the backend sizes it to
// the input). We port the GLSL form — it needs no unwired uniform and is exactly what the
// golden computed. (At input resolution the two formulas would also agree numerically.)
//
// No-layout effect: backend synthesizes the Params UBO (engine globals + uDisplacement);
// none referenced here. Single input `statsTex` (= statsTiles) at set 0, binding 1.
//
// COORDINATE NOTE: gl_FragCoord top-left, NO Y-flip. textureLoad -> texelFetch;
// textureDimensions -> textureSize.
layout(set = 0, binding = 1) uniform sampler2D statsTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float F32_MAX = 3.402823466e38;
const float F32_MIN = -3.402823466e38;
const int TILE_SIZE = 8;
const int MAX_TILE_DIM = 512; // Supports resolutions up to 4096px.

void main() {
	// Single pixel output; ensure only the first fragment runs the reduction.
	if (int(gl_FragCoord.x) != 0 || int(gl_FragCoord.y) != 0) {
		frag = vec4(0.0);
		return;
	}

	ivec2 statsTexSize = textureSize(statsTex, 0);
	ivec2 tileCount = ivec2(
		(statsTexSize.x + TILE_SIZE - 1) / TILE_SIZE,
		(statsTexSize.y + TILE_SIZE - 1) / TILE_SIZE
	);

	float globalMin = F32_MAX;
	float globalMax = F32_MIN;

	for (int ty = 0; ty < MAX_TILE_DIM; ty = ty + 1) {
		if (ty >= tileCount.y) {
			break;
		}
		for (int tx = 0; tx < MAX_TILE_DIM; tx = tx + 1) {
			if (tx >= tileCount.x) {
				break;
			}
			ivec2 sampleCoord = ivec2(tx * TILE_SIZE, ty * TILE_SIZE);
			vec2 tileStats = texelFetch(statsTex, sampleCoord, 0).xy;
			globalMin = min(globalMin, tileStats.x);
			globalMax = max(globalMax, tileStats.y);
		}
	}

	frag = vec4(globalMin, globalMax, 0.0, 1.0);
}

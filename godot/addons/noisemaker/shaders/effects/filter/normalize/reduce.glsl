#version 450
// filter/normalize program "reduce" — ported PIXEL-IDENTICALLY from wgsl/reduce.wgsl.
// GPGPU pass 1: 16:1 pyramid reduction from the original image. Each output texel covers
// a 16x16 block of input; emits (minRGB, maxRGB) of that block.
//
// No-layout effect (normalize.json globals == {}): the backend SYNTHESIZES the Params UBO
// (engine globals only; none referenced here). Single input `inputTex` at set 0, binding 1
// (pass.inputs order).
//
// COORDINATE NOTE: ported from WGSL (top-left). outCoord = ivec2(gl_FragCoord.xy), exactly
// the WGSL `vec2<i32>(position.xy)`. NO Y-flip; NO tileOffset/fullResolution remap (the WGSL
// has none — we do not reproduce the reference GLSL's globalCoord computation, which it never
// uses). textureLoad(t, coord, 0) -> texelFetch(t, coord, 0). textureDimensions -> textureSize.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 outCoord = ivec2(gl_FragCoord.xy);
	ivec2 inSize = textureSize(inputTex, 0);

	// Each output pixel covers a 16x16 area of input
	ivec2 baseCoord = outCoord * 16;

	float minVal = 100000.0;
	float maxVal = -100000.0;

	// Sample 16x16 block
	for (int dy = 0; dy < 16; dy = dy + 1) {
		for (int dx = 0; dx < 16; dx = dx + 1) {
			ivec2 sampleCoord = baseCoord + ivec2(dx, dy);

			// Skip if out of bounds
			if (sampleCoord.x >= inSize.x || sampleCoord.y >= inSize.y) {
				continue;
			}

			vec4 color = texelFetch(inputTex, sampleCoord, 0);

			// Compute RGB min/max
			float pixelMin = min(min(color.r, color.g), color.b);
			float pixelMax = max(max(color.r, color.g), color.b);

			minVal = min(minVal, pixelMin);
			maxVal = max(maxVal, pixelMax);
		}
	}

	// Store min in r, max in g
	frag = vec4(minVal, maxVal, 0.0, 1.0);
}

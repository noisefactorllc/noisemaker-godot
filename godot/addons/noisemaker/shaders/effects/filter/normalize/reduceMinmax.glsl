#version 450
// filter/normalize program "reduceMinmax" — ported PIXEL-IDENTICALLY from
// wgsl/reduceMinmax.wgsl. GPGPU pass 2: 16:1 reduction of the min/max texture from pass 1
// (min in .r, max in .g). Each output texel covers a 16x16 block of input.
//
// No-layout effect (normalize.json globals == {}): backend synthesizes the Params UBO
// (engine globals only; none referenced here). Single input `inputTex` (= reduce1) at
// set 0, binding 1.
//
// COORDINATE NOTE: ported from WGSL (top-left). outCoord = ivec2(gl_FragCoord.xy). NO
// Y-flip. textureLoad -> texelFetch; textureDimensions -> textureSize.
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

			// Input has min in .r, max in .g
			minVal = min(minVal, color.r);
			maxVal = max(maxVal, color.g);
		}
	}

	frag = vec4(minVal, maxVal, 0.0, 1.0);
}

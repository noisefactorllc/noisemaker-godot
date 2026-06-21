#version 450
// filter/normalize program "statsFinal" — ported PIXEL-IDENTICALLY from wgsl/statsFinal.wgsl.
// GPGPU pass 3: final reduction to a 1x1 min/max by scanning the entire input texture
// (min in .r, max in .g from the pyramid reduction).
//
// No-layout effect (normalize.json globals == {}): backend synthesizes the Params UBO
// (engine globals only; none referenced here). Single input `inputTex` (= reduce2) at
// set 0, binding 1.
//
// COORDINATE NOTE: ported from WGSL (top-left). Full-texture scan, no fragcoord use. NO
// Y-flip. textureLoad -> texelFetch; textureDimensions -> textureSize.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 inSize = textureSize(inputTex, 0);

	float minVal = 100000.0;
	float maxVal = -100000.0;

	// Scan entire texture
	for (int y = 0; y < inSize.y; y = y + 1) {
		for (int x = 0; x < inSize.x; x = x + 1) {
			vec4 color = texelFetch(inputTex, ivec2(x, y), 0);

			// Input has min in .r, max in .g
			minVal = min(minVal, color.r);
			maxVal = max(maxVal, color.g);
		}
	}

	frag = vec4(minVal, maxVal, 0.0, 1.0);
}

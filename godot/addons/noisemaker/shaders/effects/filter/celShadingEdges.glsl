#version 450
// filter/celShading program "celShadingEdges" — ported from
// wgsl/celShadingEdges.wgsl. Sobel edge detection on the quantized colors.
// Pass 2 of 3: celShadingColorTex -> celShadingEdgeTex.
//
// No-layout effect: backend injects the Params UBO + `#define edgeWidth …`/
// `edgeThreshold …` and engine globals (incl. `renderScale`). The single input
// `colorTex` (= celShadingColorTex) is bound at set 0, binding 1 (pass.inputs order).
//
// PORTING NOTES:
//  * Ported from WGSL (top-left, canonical) — NO per-effect Y flip.
//  * Integer texel fetch: WGSL `textureLoad(colorTex, ivec2, 0)` -> texelFetch,
//    with REPEAT wrapping done by wrapCoord. texelFetch (not texture()) is required
//    so the wrapCoord-computed integer indices fetch exactly that texel and the
//    REPEAT wrap is honoured at the borders (clamp-to-edge would differ there).
//  * coord = ivec2(gl_FragCoord.xy) — truncation of the +0.5-centered fragCoord,
//    matching WGSL `vec2<i32>(pos.xy)`.
//  * renderScale: WGSL `select(uniforms.renderScale, 1.0, uniforms.renderScale<=0.0)`
//    (select operands reversed vs ternary) yields 1.0 when renderScale<=0, else
//    renderScale. Reproduced as the equivalent ternary.
//  * edgeWidth is an int param: WGSL `i32(uniforms.edgeWidth * renderScale)`.
//  * helpers (getLuminosity, wrapCoord) are this effect's OWN copies, inlined
//    verbatim. Arithmetic reproduced literally; full f32.
layout(set = 0, binding = 1) uniform sampler2D colorTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// getLuminosity — VERBATIM from celShadingEdges.wgsl. Per-effect copy.
float getLuminosity(vec3 color) {
	return dot(color, vec3(0.299, 0.587, 0.114));
}

// wrapCoord — VERBATIM from celShadingEdges.wgsl. Per-effect copy.
int wrapCoord(int value, int size) {
	if (size <= 0) {
		return 0;
	}
	int wrapped = value % size;
	if (wrapped < 0) {
		wrapped = wrapped + size;
	}
	return wrapped;
}

void main() {
	ivec2 texSize = ivec2(textureSize(colorTex, 0));
	if (texSize.x == 0 || texSize.y == 0) {
		frag = vec4(0.0);
		return;
	}

	ivec2 coord = ivec2(gl_FragCoord.xy);

	// Sample 3x3 neighborhood with thickness scaling. Mirrors GLSL: clamp to minimum 1
	// so offset never collapses all 9 taps onto the same pixel.
	float renderScaleVal = renderScale <= 0.0 ? 1.0 : renderScale;
	int offset = max(1, int(edgeWidth * renderScaleVal));
	float samples[9];
	int idx = 0;
	for (int ky = -1; ky <= 1; ky = ky + 1) {
		for (int kx = -1; kx <= 1; kx = kx + 1) {
			int sampleX = wrapCoord(coord.x + kx * offset, texSize.x);
			int sampleY = wrapCoord(coord.y + ky * offset, texSize.y);
			vec4 texel = texelFetch(colorTex, ivec2(sampleX, sampleY), 0);
			samples[idx] = getLuminosity(texel.rgb);
			idx = idx + 1;
		}
	}

	// Sobel X kernel: [-1 0 1; -2 0 2; -1 0 1]
	float gx = -samples[0] + samples[2] - 2.0*samples[3] + 2.0*samples[5] - samples[6] + samples[8];

	// Sobel Y kernel: [-1 -2 -1; 0 0 0; 1 2 1]
	float gy = -samples[0] - 2.0*samples[1] - samples[2] + samples[6] + 2.0*samples[7] + samples[8];

	// Calculate edge magnitude
	float magnitude = sqrt(gx * gx + gy * gy);

	// Apply threshold with smoothstep for anti-aliased edges
	float edge = smoothstep(edgeThreshold * 0.5, edgeThreshold * 1.5, magnitude);

	frag = vec4(edge, edge, edge, 1.0);
}

#version 450
// filter/smooth program "smoothEdge" — ported from wgsl/smoothEdge.wgsl.
// Pass 1 of 2. SMAA (type 1) / Blur (type 2): write a luma edge map
// (R = horizontal edge flag, G = vertical edge flag). MSAA (type 0): pass the
// input through unchanged. Output target is the internal _smoothEdges texture.
// No-layout effect: backend injects the Params UBO + `#define smoothType …`/
// `threshold …` and engine globals. Input bound at set 0, binding 1
// (pass.inputs order: inputTex). Backend sampler is NEAREST + clamp-to-edge,
// so texture() at integer-texel coords reproduces the WGSL textureLoad fetches.
//
// Reserved-name collision: WGSL locals `smoothType`/`threshold` are param names
// (injected as `#define`s) — captured into renamed locals (localType/thr), a
// pure rename, no behavior change (the HLSL port does the same).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const vec3 LUMA_WEIGHTS = vec3(0.299, 0.587, 0.114);

float luminance(vec3 rgb) {
	return dot(rgb, LUMA_WEIGHTS);
}

void main() {
	int localType = int(smoothType);
	float thr = threshold;

	ivec2 size = ivec2(textureSize(inputTex, 0));
	ivec2 coord = ivec2(int(gl_FragCoord.x), int(gl_FragCoord.y));

	// MSAA mode: pass through input (blend pass does its own edge detection)
	if (localType == 0) {
		frag = texelFetch(inputTex, coord, 0);
		return;
	}

	// SMAA and Blur modes: luma-based edge detection
	ivec2 maxCoord = size - ivec2(1);
	float L  = luminance(texelFetch(inputTex, coord, 0).rgb);
	float Ln = luminance(texelFetch(inputTex, clamp(coord + ivec2(0, -1), ivec2(0), maxCoord), 0).rgb);
	float Ls = luminance(texelFetch(inputTex, clamp(coord + ivec2(0,  1), ivec2(0), maxCoord), 0).rgb);
	float Lw = luminance(texelFetch(inputTex, clamp(coord + ivec2(-1, 0), ivec2(0), maxCoord), 0).rgb);
	float Le = luminance(texelFetch(inputTex, clamp(coord + ivec2( 1, 0), ivec2(0), maxCoord), 0).rgb);

	float edgeH = step(thr, max(abs(L - Ln), abs(L - Ls)));
	float edgeV = step(thr, max(abs(L - Lw), abs(L - Le)));

	frag = vec4(edgeH, edgeV, 0.0, 1.0);
}

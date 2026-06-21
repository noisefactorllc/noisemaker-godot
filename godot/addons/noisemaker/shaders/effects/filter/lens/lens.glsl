#version 450
// filter/lens — ported PIXEL-IDENTICALLY from the reference glsl/lens.glsl (the
// webgl2 golden is rendered from THAT GLSL). Barrel/pincushion lens distortion: a
// COORD-RESAMPLING warp that displaces the sample coordinate radially around the
// frame center, then resamples the input there.
//
// No-layout effect (lens.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects, after #version, a `#define <name> data[slot].comp` for
// every engine global and every param uniform (lensDisplacement, aspectLens,
// antialias). So we use the bare reference names directly and declare NO UBO and
// NO uniforms. The input texture is bound at set 0, binding 1 (pass.inputs order).
// No shared nm_core primitives are used, so nm_core.glsl is NOT included.
//
// COORDINATE / TILING NOTE: the reference GLSL is tile-aware (uses fullResolution /
// tileOffset / resolution uniforms). In this (and every) parity render the backend
// injects tileOffset = (0,0) and fullResolution == resolution == the render size,
// and inputTex IS that render size, so textureSize(inputTex,0) == fullResolution ==
// the GLSL `dims` and `tileDims`. With tileOffset == 0 the reference's
// `isTileRendering = length(tileOffset) > 0.0` is FALSE, so the NON-TILING branch
// runs and the tile-local remap collapses to identity:
//   dims = fullResolution; uv = gl_FragCoord.xy / dims;
//   warpedGlobalUV = fract(uv - displacement);
//   offset = (warpedGlobalUV * dims - tileOffset) / tileDims  ==  fract(uv - displacement)
// This matches the established filter-port convention (pinch/tile/flipMirror): use
// textureSize(inputTex,0) for dims and reproduce only the non-tiling interior path.
// gl_FragCoord is top-left/+0.5 like the reference — NO Y-flip.
//
// TRANSLATION HAZARDS:
//  * aspectLens / antialias are boolean params -> the synthesized layout delivers
//    them as float `data[].comp`. The reference tests `if (aspectLens)` / `if
//    (antialias)`; we narrow with `int(...) != 0` at each site to match.
//  * lensDisplacement is the bare injected param name; used verbatim where the
//    reference used the uniform (no `let`/alias to drop).
//  * Sampler is NEAREST for effect targets (matches the reference render targets),
//    so we sample at the computed coord directly via plain texture().
//  * The antialias branch uses screen-space derivatives (dFdx/dFdy) to place 4
//    rotated-grid taps; literals (±0.375 / ±0.125) and the *0.25 average copied
//    verbatim from the reference.
//  * Constants copied verbatim: HALF_FRAME = 0.5, zoom factor -0.25, maxDispPixels
//    256.0 (tiling-only; unused on this path but kept for fidelity). No arithmetic
//    reassociation. (Reference GLSL and WGSL agree on all of these.)
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float HALF_FRAME = 0.5;

void main() {
	ivec2 texSizeI = textureSize(inputTex, 0);
	vec2 tileDims = vec2(texSizeI);
	vec2 dims = tileDims;
	vec2 uv = gl_FragCoord.xy / dims;

	// Zoom for negative displacement (pincushion)
	float zoom = (lensDisplacement < 0.0) ? (lensDisplacement * -0.25) : 0.0;

	// Distance from center, optionally aspect-corrected for circular distortion
	float aspect = dims.x / dims.y;
	vec2 dist = uv - HALF_FRAME;
	vec2 aDist = dist;
	if (int(aspectLens) != 0) { aDist.x *= aspect; }

	float maxDist = length(vec2(int(aspectLens) != 0 ? aspect * 0.5 : 0.5, 0.5));
	float distFromCenter = length(aDist);
	float normalizedDist = clamp(distFromCenter / maxDist, 0.0, 1.0);

	// Stronger effect near edges, weaker at center
	float centerWeight = 1.0 - normalizedDist;
	float centerWeightSq = centerWeight * centerWeight;

	// Apply radial distortion in aspect-corrected space
	vec2 displacement = aDist * zoom + aDist * centerWeightSq * lensDisplacement;

	// Convert displacement back to UV space
	if (int(aspectLens) != 0) { displacement.x /= aspect; }

	// Non-tiling parity render: tileOffset == 0, so isTileRendering is false and the
	// fract() wrap path runs. offset = (fract(uv - displacement) * dims - 0) / dims.
	vec2 warpedGlobalUV = fract(uv - displacement);
	vec2 offset = (warpedGlobalUV * dims) / tileDims;

	vec2 sampledUV = offset;

	if (int(antialias) != 0) {
		vec2 dx = dFdx(sampledUV);
		vec2 dy = dFdy(sampledUV);
		vec4 col = vec4(0.0);

		col += texture(inputTex, sampledUV + dx * -0.375 + dy * -0.125);
		col += texture(inputTex, sampledUV + dx *  0.125 + dy * -0.375);
		col += texture(inputTex, sampledUV + dx *  0.375 + dy *  0.125);
		col += texture(inputTex, sampledUV + dx * -0.125 + dy *  0.375);

		frag = col * 0.25;
	} else {
		frag = texture(inputTex, sampledUV);
	}
}

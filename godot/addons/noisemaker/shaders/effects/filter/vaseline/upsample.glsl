#version 450
// filter/vaseline (program "upsample") — ported PIXEL-IDENTICALLY from
// wgsl/upsample.wgsl. A 32-tap golden-angle-spiral blur, brightness-boosted and
// edge-masked (Chebyshev), blended back over the source by `alpha`. Single render
// pass (progName "upsample").
//
// No-layout effect (vaseline.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define alpha …` plus the engine `#define resolution …`
// (the WGSL param struct's `resolution` IS the engine resolution global — screen
// size). We use the bare names `alpha`/`resolution` directly and declare NO UBO / NO
// uniforms. Input texture bound at set 0, binding 1.
//
// COORDINATE NOTE: WGSL gathers in UV space derived from `params.resolution`
// (== engine `resolution`); for this single-tile filter that equals
// textureSize(inputTex). gl_FragCoord is top-left (matches WGSL); NO Y-flip. WGSL
// `textureLoad(inputTex, vec2i(fragCoord.xy), 0)` → texelFetch(); the spiral
// `textureSample` taps → texture(). RADIUS is NOT multiplied by renderScale (the
// reference GLSL does, but we port the WGSL, which does not). Constants verbatim from
// WGSL (GOLDEN_ANGLE 2.39996323, RADIUS 48, sigma 0.4, BRIGHTNESS_ADJUST 0.15). No
// arithmetic reassociation. `clamp01v`/`chebyshev_mask` are this effect's own helpers.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const int TAP_COUNT = 32;
const float RADIUS = 48.0;
const float GOLDEN_ANGLE = 2.39996323;
const float BRIGHTNESS_ADJUST = 0.15;

// clamp01v — verbatim from WGSL: clamp(v, vec3f(0.0), vec3f(1.0));
vec3 clamp01v(vec3 v) {
	return clamp(v, vec3(0.0), vec3(1.0));
}

// chebyshev_mask — verbatim from WGSL.
//   let centered = abs(uv - vec2f(0.5)) * 2.0;
//   return max(centered.x, centered.y);
float chebyshev_mask(vec2 uv) {
	vec2 centered = abs(uv - vec2(0.5)) * 2.0;
	return max(centered.x, centered.y);
}

void main() {
	// WGSL: let coord = vec2i(fragCoord.xy); let fullSize = params.resolution;
	//       let uv = (vec2f(coord) + 0.5) / fullSize;
	ivec2 coord = ivec2(gl_FragCoord.xy);
	vec2 fullSize = resolution;
	vec2 uv = (vec2(coord) + 0.5) / fullSize;

	// WGSL: let original = textureLoad(inputTex, coord, 0); let a = clamp(alpha,0,1);
	vec4 original = texelFetch(inputTex, coord, 0);
	float a = clamp(alpha, 0.0, 1.0);

	if (a <= 0.0) {
		frag = vec4(clamp01v(original.rgb), original.a);
		return;
	}

	// WGSL: let texelSize = 1.0 / fullSize; let radiusUV = RADIUS * texelSize;
	vec2 texelSize = 1.0 / fullSize;
	vec2 radiusUV = RADIUS * texelSize;

	// N-tap gather using golden angle spiral.
	vec3 blurAccum = vec3(0.0);
	float weightSum = 0.0;

	for (int i = 0; i < TAP_COUNT; i = i + 1) {
		float t = float(i) / float(TAP_COUNT);
		float r = sqrt(t);
		float theta = float(i) * GOLDEN_ANGLE;
		vec2 offset = vec2(cos(theta), sin(theta)) * r;

		float sigma = 0.4;
		float weight = exp(-0.5 * (r * r) / (sigma * sigma));

		vec2 sampleUV = clamp(uv + offset * radiusUV, vec2(0.0), vec2(1.0));
		blurAccum = blurAccum + texture(inputTex, sampleUV).rgb * weight;
		weightSum = weightSum + weight;
	}

	// WGSL: let blurred = blurAccum / weightSum;
	//       let boosted = clamp01v(blurred + vec3f(BRIGHTNESS_ADJUST));
	vec3 blurred = blurAccum / weightSum;
	vec3 boosted = clamp01v(blurred + vec3(BRIGHTNESS_ADJUST));

	// Edge mask — more effect at edges.
	float edgeMask = chebyshev_mask(uv);
	edgeMask = smoothstep(0.0, 0.8, edgeMask);

	vec3 sourceClamped = clamp01v(original.rgb);
	vec3 bloomed = clamp01v((sourceClamped + boosted) * 0.5);
	vec3 edgeBlended = mix(sourceClamped, bloomed, edgeMask);
	vec3 finalRgb = clamp01v(mix(sourceClamped, edgeBlended, a));

	frag = vec4(finalRgb, original.a);
}

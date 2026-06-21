#version 450
// filter/vignette — ported from wgsl/vignette.wgsl. Radial vignette: darkens
// (blends toward a brightness value) the edges by a squared, aspect-corrected
// normalized distance from center, then cross-fades that result with the
// original via `alpha`. RGB only; alpha is passed through. Single render pass.
// No-layout effect: the backend injects the Params UBO + `#define vignetteBrightness …`/
// `#define alpha …` (synthesized layout) and engine globals, so we use the bare
// reference names directly. Input texture bound at set 0, binding 1.
// gl_FragCoord is top-left (matches WGSL @builtin(position)); no per-effect Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float computeVignetteMask(vec2 uv, vec2 dims) {
	if (dims.x <= 0.0 || dims.y <= 0.0) {
		return 0.0;
	}

	vec2 delta = abs(uv - vec2(0.5));
	float aspect = dims.x / max(dims.y, 1.0);
	vec2 scaled = vec2(delta.x * aspect, delta.y);
	float maxRadius = length(vec2(aspect * 0.5, 0.5));

	if (maxRadius <= 0.0) {
		return 0.0;
	}

	float normalizedDist = clamp(length(scaled) / maxRadius, 0.0, 1.0);
	return normalizedDist * normalizedDist;
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	vec4 texel = texture(inputTex, uv);

	float mask = computeVignetteMask(uv, texSize);

	// Apply brightness to RGB only, preserve alpha
	vec3 brightnessRgb = vec3(vignetteBrightness);
	vec3 edgeBlend = mix(texel.rgb, brightnessRgb, mask);
	vec3 finalRgb = mix(texel.rgb, edgeBlend, alpha);

	frag = vec4(finalRgb, texel.a);
}

#version 450
// filter/reverb — ported PIXEL-IDENTICALLY from wgsl/reverb.wgsl. Visual reverb/echo:
// blend the input with successively scaled-down (×2 each octave) wrapped copies of
// itself. Single render pass (progName "reverb").
//
// No-layout effect (reverb.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define <name> data[slot].comp` for the params iterations
// (int), ridges (bool→float), alpha (float), wrap (int→float). We use the bare names.
// `ridges` arrives as 0.0/1.0 → tested `!= 0.0`. `wrap`/`iterations` cast to int.
//
// COORDINATE NOTE: ported from WGSL (top-left): uv = gl_FragCoord.xy / textureSize, and
// scaled samples are taken at applyWrap(uv * scale) directly — we do NOT reproduce the
// reference GLSL's globalUV/fullResolution sampling remap (the WGSL has none). WGSL
// `textureSample` → `texture()` (linear, but samples land on the clamped/fract'd grid).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

vec2 applyWrap(vec2 uv) {
	int mode = int(wrap);
	if (mode == 0) {
		// Mirror: abs(mod(uv + 1, 2) - 1)
		float mx = abs((uv.x + 1.0) - floor((uv.x + 1.0) * 0.5) * 2.0 - 1.0);
		float my = abs((uv.y + 1.0) - floor((uv.y + 1.0) * 0.5) * 2.0 - 1.0);
		return vec2(mx, my);
	} else if (mode == 1) {
		return fract(uv);  // repeat
	}
	return clamp(uv, vec2(0.0), vec2(1.0));  // clamp
}

vec4 ridge_transform(vec4 color) {
	return vec4(1.0) - abs(color * 2.0 - vec4(1.0));
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / dims;

	// Save original input for alpha blending
	vec4 original = texture(inputTex, uv);

	// Sample at current position
	vec4 current = original;

	// Apply ridge transform if enabled
	bool useRidges = ridges != 0.0;
	if (useRidges) {
		current = ridge_transform(current);
	}

	// Accumulate multiple scaled samples based on iterations
	vec4 accum = current;
	float totalWeight = 1.0;
	float weight = 0.5;
	float scaleVal = 2.0;

	int iters = clamp(int(iterations), 1, 8);
	for (int i = 0; i < iters; i = i + 1) {
		vec2 scaledUV = applyWrap(uv * scaleVal);
		vec4 scaled = texture(inputTex, scaledUV);

		if (useRidges) {
			scaled = ridge_transform(scaled);
		}

		accum = accum + scaled * weight;
		totalWeight = totalWeight + weight;

		scaleVal = scaleVal * 2.0;
		weight = weight * 0.5;
	}

	vec4 result = accum / totalWeight;

	frag = vec4(mix(original.rgb, result.rgb, alpha), 1.0);
}

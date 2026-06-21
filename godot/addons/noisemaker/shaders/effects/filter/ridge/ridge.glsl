#version 450
// filter/ridge — ported PIXEL-IDENTICALLY from the reference. Per-pixel "ridge"
// (crease) transform: maps each channel value toward its distance from a midpoint
// `level`, peaking at the level and falling off to both ends, clamped to [0,1].
// Single render pass (progName "ridge").
//
// SOURCE NOTE: the reference WGSL (wgsl/ridge.wgsl) is a COMPUTE shader writing a
// storage buffer; the reference GLSL (glsl/ridge.glsl) is the equivalent FRAGMENT
// shader. Our pipeline is fragment-based, so this is ported from the GLSL render
// form (the math is identical to the compute `ridge_transform`). UV = fragCoord /
// input texture size, top-left, no Y-flip (matches the GLSL `gl_FragCoord.xy /
// vec2(dims)`).
//
// No-layout effect (ridge.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define level data[slot].comp` (+ engine globals). So we
// use the bare name `level` directly and declare NO UBO / NO uniforms. The input
// texture is bound at set 0, binding 1 (pass.inputs order). No shared nm_core
// primitives are used, so nm_core.glsl is NOT included.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// ridge_transform — verbatim from the reference.
//   float denom = max(lvl, 1.0 - lvl);
//   vec4 result = vec4(1.0) - abs(value - vec4(lvl)) / denom;
//   return clamp(result, vec4(0.0), vec4(1.0));
vec4 ridge_transform(vec4 value, float lvl) {
	float denom = max(lvl, 1.0 - lvl);
	vec4 result = vec4(1.0) - abs(value - vec4(lvl)) / denom;
	return clamp(result, vec4(0.0), vec4(1.0));
}

void main() {
	// Reference: vec2 uv = gl_FragCoord.xy / vec2(dims); (dims = textureSize(inputTex)).
	ivec2 dims = textureSize(inputTex, 0);
	vec2 uv = gl_FragCoord.xy / vec2(dims);

	vec4 texel = texture(inputTex, uv);

	// Apply ridge transform.
	vec4 ridged = ridge_transform(texel, level);
	vec4 out_color = vec4(ridged.xyz, 1.0);

	frag = out_color;
}

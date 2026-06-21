#version 450
// filter/glowingEdge — ported from wgsl/glowingEdge.wgsl. Single-pass Sobel edge
// detection with screen-blend glow. Ported from WGSL (top-left origin = Godot/
// Vulkan), no per-effect Y-flip.
// No-layout effect: the backend injects the Params UBO + `#define sobelMetric …`/
// `#define width …`/`#define alpha …` (synthesized layout) and engine globals, so
// we use the bare reference names directly. Input texture bound at set 0, binding 1.
//
// WGSL used textureSampleLevel(..., 0.0) (explicit mip 0, no derivatives) because
// noisemaker textures are rgba16float; the Godot backend sampler is NEAREST and the
// textures have a single mip, so plain texture() at mip 0 is the parity-faithful map.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float luminance(vec3 rgb) {
	return dot(rgb, vec3(0.299, 0.587, 0.114));
}

float distance_metric(float gx, float gy, int metric) {
	float abs_gx = abs(gx);
	float abs_gy = abs(gy);

	if (metric == 1) {
		return abs_gx + abs_gy;  // Manhattan
	} else if (metric == 2) {
		return max(abs_gx, abs_gy);  // Chebyshev
	} else if (metric == 3) {
		float cross_val = (abs_gx + abs_gy) / 1.414;
		return max(cross_val, max(abs_gx, abs_gy));  // Minkowski
	}
	return sqrt(gx * gx + gy * gy);  // Euclidean (0)
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec2 texel = width / texSize;

	// Sample base color
	vec4 base = texture(inputTex, uv);

	// Sample 3x3 neighborhood for Sobel
	float tl = luminance(texture(inputTex, uv + vec2(-texel.x, -texel.y)).rgb);
	float tc = luminance(texture(inputTex, uv + vec2(0.0, -texel.y)).rgb);
	float tr = luminance(texture(inputTex, uv + vec2(texel.x, -texel.y)).rgb);
	float ml = luminance(texture(inputTex, uv + vec2(-texel.x, 0.0)).rgb);
	float mr = luminance(texture(inputTex, uv + vec2(texel.x, 0.0)).rgb);
	float bl = luminance(texture(inputTex, uv + vec2(-texel.x, texel.y)).rgb);
	float bc = luminance(texture(inputTex, uv + vec2(0.0, texel.y)).rgb);
	float br = luminance(texture(inputTex, uv + vec2(texel.x, texel.y)).rgb);

	// Sobel kernels
	float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
	float gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;

	// Edge magnitude
	int metric = int(sobelMetric);
	float edge = clamp(distance_metric(gx, gy, metric) * 3.0, 0.0, 1.0);

	// Glow: edges emit the base color as additive light
	vec3 glow = edge * base.rgb * 2.0;

	// Screen blend glow onto original
	vec3 result = vec3(1.0) - (vec3(1.0) - base.rgb) * (vec3(1.0) - glow);

	// Mix based on alpha
	vec3 mixed = mix(base.rgb, result, alpha);

	frag = vec4(clamp(mixed, vec3(0.0), vec3(1.0)), base.a);
}

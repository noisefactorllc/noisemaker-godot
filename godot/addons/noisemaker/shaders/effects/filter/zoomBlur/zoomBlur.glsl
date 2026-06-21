#version 450
// filter/zoomBlur — ported PIXEL-IDENTICALLY from wgsl/zoomBlur.wgsl. Radial
// blur emanating from the center: 41 samples along the ray from each pixel to
// the center, weighted by a parabola, with a PRNG sub-sample offset to hide the
// fixed tap count. Single render pass (progName "zoomBlur").
//
// No-layout effect (zoomBlur.json has no uniformLayout): the backend SYNTHESIZES
// the Params UBO and injects `#define strength data[slot].comp` plus the engine
// globals. We use bare `strength` directly. Input texture at set 0, binding 1.
//
// COORDINATE NOTE: ported from WGSL (top-left, no Y-flip): uv = gl_FragCoord.xy /
// textureSize(inputTex). The reference GLSL's tileOffset/fullResolution global-UV
// remap is a tiling concern we do not reproduce (WGSL has none). `textureSampleLevel
// (.., 0.0)` → `texture(..)` (no mipmaps). prng helper inlined verbatim from WGSL.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// PCG PRNG (verbatim from wgsl/zoomBlur.wgsl).
uvec3 pcg(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v = v ^ (v >> uvec3(16u));
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

vec3 prng(vec3 p) {
	return vec3(pcg(uvec3(p))) / float(0xffffffffu);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	vec3 color = vec3(0.0);
	float total = 0.0;
	vec2 toCenter = uv - 0.5;

	// Randomize the lookup values to hide the fixed number of samples.
	float offset = prng(vec3(12.9898, 78.233, 151.7182)).x;

	for (float t = 0.0; t <= 40.0; t += 1.0) {
		float percent = (t + offset) / 40.0;
		float weight = 4.0 * (percent - percent * percent);
		vec4 tex = texture(inputTex, uv + toCenter * percent * strength);
		color += tex.rgb * weight;
		total += weight;
	}

	color /= total;

	frag = vec4(color, 1.0);
}

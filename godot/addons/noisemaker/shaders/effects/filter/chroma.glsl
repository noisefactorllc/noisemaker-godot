#version 450
// filter/chroma — ported PIXEL-IDENTICALLY from wgsl/chroma.wgsl.
// Isolate a specific hue range from the input texture; outputs a mono mask
// (value = mask in RGB, alpha passed through).
// No-layout effect: the backend injects the Params UBO + `#define targetHue …`/
// `#define range …`/`#define feather …` (synthesized layout) and engine globals,
// so we use the bare reference names directly. Input texture bound at set 0,
// binding 1 (pass.inputs order). No Y-flip.
//
// rgb2hsv and hueDistance are this effect's OWN copies — ported VERBATIM inline.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// rgb2hsv — ported VERBATIM from chroma.wgsl. Per-effect copy.
vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// hueDistance — ported VERBATIM from chroma.wgsl. Per-effect copy.
float hueDistance(float h1, float h2) {
	float d = abs(h1 - h2);
	return min(d, 1.0 - d);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 color = texture(inputTex, uv);

	vec3 hsv = rgb2hsv(color.rgb);
	float hue = hsv.x;
	float sat = hsv.y;

	float dist = hueDistance(hue, targetHue);

	// Apply range and feather to create smooth mask
	float inner = range;
	float outer = range + feather;
	float mask = 1.0 - smoothstep(inner, outer, dist);

	// Scale by saturation - desaturated colors don't have meaningful hue
	mask *= sat;

	frag = vec4(vec3(mask), color.a);
}

#version 450
// filter/bc — ported from wgsl/bc.wgsl. Brightness and contrast adjustment
// (deprecated; use filter/adjust instead).
// No-layout effect: the backend injects the Params UBO + `#define brightness …`/
// `#define contrast …` (synthesized layout) and engine globals, so we use the
// bare reference names directly. Input texture bound at set 0, binding 1.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec4 color = texture(inputTex, uv);

	// Apply brightness (multiply)
	color = vec4(color.rgb * brightness, color.a);

	// Apply contrast (0..1 -> 0..2)
	float contrastFactor = contrast * 2.0;
	color = vec4((color.rgb - 0.5) * contrastFactor + 0.5, color.a);

	frag = color;
}

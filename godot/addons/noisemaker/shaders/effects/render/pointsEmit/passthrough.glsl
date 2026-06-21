#version 450
// render/pointsEmit — program "passthrough" (forward the chained input downstream while
// the init pass updates agent state out-of-band). Ported from glsl/passthrough.glsl.
// Layout effect: vec4 data[1] (uniformLayouts.passthrough): resolution=data[0].xy.
// Input: inputTex=1. gl_FragCoord top-left — NO Y-flip.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
#define resolution data[0].xy
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) out vec4 fragColor;
layout(location = 0) in vec2 v_uv;

void main() {
	vec2 uv = gl_FragCoord.xy / resolution;
	fragColor = texture(inputTex, uv);
}

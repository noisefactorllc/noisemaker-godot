#version 450
// render/pointsRender — program "copy" (blit trail to itself for ping-pong correction:
// synchronises both double-buffers so the additive deposit accumulates onto the faded
// trail regardless of which physical buffer it targets). Ported from glsl/copy.glsl.
// Layout effect: vec4 data[1] (uniformLayouts.copy): resolution=data[0].xy.
// Input: sourceTex=1. gl_FragCoord top-left — NO Y-flip.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
#define resolution data[0].xy
layout(set = 0, binding = 1) uniform sampler2D sourceTex;
layout(location = 0) out vec4 fragColor;
layout(location = 0) in vec2 v_uv;

void main() {
	vec2 uv = gl_FragCoord.xy / resolution;
	fragColor = texture(sourceTex, uv);
}

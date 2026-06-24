#version 450
// render/pointsBillboardRender — program "diffuse" (decay the persistent billboard trail).
// Ported from glsl/diffuse.glsl. intensity=100 no decay, 0 instant fade.
// Layout effect: vec4 data[1] (uniformLayouts.diffuse): resolution=data[0].xy,
// intensity=data[0].z. Input: trailTex=1. gl_FragCoord top-left — NO Y-flip.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
#define resolution data[0].xy
#define intensity data[0].z
layout(set = 0, binding = 1) uniform sampler2D trailTex;
layout(location = 0) out vec4 fragColor;
layout(location = 0) in vec2 v_uv;

void main() {
	vec2 uv = gl_FragCoord.xy / resolution;

	// Sample the trail texture directly (no blur)
	vec4 trailColor = texture(trailTex, uv);

	// Apply intensity decay (persistence)
	float decay = clamp(intensity / 100.0, 0.0, 1.0);
	fragColor = clamp(trailColor * decay, 0.0, 1.0);
}

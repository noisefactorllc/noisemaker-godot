#version 450
// filter/temporalAberration — program "delayShift" (one stage of the delay line). Ported from
// glsl/delayShift.glsl. Copies the source stage into the destination, advancing the
// bucket-brigade shift register one frame; alpha is preserved so the filled-frontier (alpha 1
// from live input vs 0 from never-written stages) propagates exactly one stage per frame,
// which the read pass uses for its ramp-in fallback.
//
// No-layout program: the backend synthesizes the Params UBO + injects `#define resolution ...`.
// The reference computes uv from textureSize(srcTex); resolution is identical (the history
// buffers are input-sized) and referencing it keeps the injected UBO live. Input: srcTex=1.
layout(set = 0, binding = 1) uniform sampler2D srcTex;
layout(location = 0) out vec4 fragColor;
layout(location = 0) in vec2 v_uv;

void main() {
	vec2 uv = gl_FragCoord.xy / resolution;
	fragColor = texture(srcTex, uv);
}

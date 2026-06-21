#version 450
// filter/motionBlur (program "motionBlur") — ported from wgsl/motionBlur.wgsl.
// FEEDBACK effect: frame-blending motion blur. Blends the live `inputTex` with the
// prior-frame feedback buffer `selfTex` by `amount`; the companion `copy` program snapshots
// the result back into selfTex each frame, and the multi-frame settle loop drives the
// accumulation (with a static input it converges to the input — a contracting blend).
//
// No-layout effect: the backend injects the Params UBO + `#define amount …`/`resetState …`
// and engine globals (`resolution`). Inputs bind at set 0 in pass.inputs order: inputTex
// (live) = binding 1, selfTex (prior frame) = binding 2. gl_FragCoord is top-left/+0.5 like
// the WGSL @position — NO Y-flip. (The WGSL struct's `seed` is unused and not a uniform —
// dropped, matching the no-layout synthesized header.)
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D selfTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 uv = gl_FragCoord.xy / resolution;

	// resetState bypasses the feedback and returns the input directly.
	if (int(resetState) != 0) {
		frag = texture(inputTex, uv);
		return;
	}

	vec4 current = texture(inputTex, uv);
	vec4 previous = texture(selfTex, uv);

	// amount 0-100 -> mix factor 0-0.8 (clamped to 0.98).
	float mixFactor = clamp(amount * 0.008, 0.0, 0.98);

	frag = mix(current, previous, mixFactor);
}

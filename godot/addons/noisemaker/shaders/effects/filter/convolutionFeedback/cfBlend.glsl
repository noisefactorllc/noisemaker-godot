#version 450
// filter/convolutionFeedback program "cfBlend" — ported from wgsl/cfBlend.wgsl.
// Final blend pass (3rd of 3) of the FEEDBACK effect. Mixes the live input with the
// processed (sharpened+blurred) feedback by `intensity`; resetState bypasses to input.
// Two inputs in pass.inputs order: inputTex (live) = binding 1, feedbackTex (= _cfBlurred)
// = binding 2.
//
// No-layout effect: backend SYNTHESIZES the Params UBO + `#define <name> data[slot].comp`;
// use bare names (intensity, resetState). resetState is a boolean param arriving as a float
// UBO component → compare int(resetState) != 0, matching the WGSL `!= 0`. The WGSL's
// `Uniforms` struct is just the reference packing.
//
// WGSL→GLSL: textureLoad→texelFetch (integer coords, no sampler — matches the WGSL).
// gl_FragCoord top-left/+0.5, NO Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D feedbackTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 coord = ivec2(gl_FragCoord.xy);

	vec4 inputColor = texelFetch(inputTex, coord, 0);

	// If resetState is true, bypass feedback and return input directly
	if (int(resetState) != 0) {
		frag = inputColor;
		return;
	}

	vec4 feedback = texelFetch(feedbackTex, coord, 0);

	// Blend input with processed feedback based on intensity
	vec3 result = mix(inputColor.rgb, feedback.rgb, intensity);

	frag = vec4(result, inputColor.a);
}

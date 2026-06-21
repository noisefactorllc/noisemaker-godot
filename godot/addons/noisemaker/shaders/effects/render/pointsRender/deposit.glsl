#version 450
// render/pointsRender — program "deposit" FRAGMENT stage (paint the agent's color into the
// trail). Ported from glsl/deposit.frag. The vertex stage (deposit.vert.glsl) scatters one
// point per agent and passes its color through; this just writes it (additive ONE,ONE blend
// is configured by the backend for blend:true point passes). No uniforms.
layout(location = 0) in vec4 vColor;
layout(location = 0) out vec4 fragColor;

void main() {
	fragColor = vColor;
}

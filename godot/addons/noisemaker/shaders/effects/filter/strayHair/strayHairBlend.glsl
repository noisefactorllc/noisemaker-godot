#version 450
// filter/strayHair program "strayHairBlend" — ported from wgsl/strayHairBlend.wgsl
// (byte-identical to fibersBlend.wgsl). Alpha-composites a stray-hair overlay onto the input:
// result = base*(1-a) + overlay*a, a = overlay.a*alpha. Single render pass.
//
// NOTE ON OVERLAY: the hair overlay (`overlayTex`) is produced on the CPU by the effect's JS
// asyncInit (traceWorms → a 2D canvas), NOT by any GPU shader — there is no overlay program to
// port. In the headless parity harness (and any pipeline driving render() directly) asyncInit
// does not run, so overlayTex is empty/zero-cleared and this blend passes the input through
// unchanged (a == 0 → base). The GLSL below is a faithful port of the only GPU program; a true
// hair overlay needs the CPU tracer.
//
// MULTI-INPUT, no-layout effect (strayHair.json has NO uniformLayout). Two inputs in
// pass.inputs order: inputTex = base (binding 1), overlayTex = CPU overlay (binding 2). The
// backend SYNTHESIZES the Params UBO + `#define <name> data[slot].comp`; the pass wires
// uniforms.alpha = `alpha`, so the bare name is `alpha`.
//
// WGSL→GLSL: textureLoad→texelFetch (integer coords, no sampler; dead binding(0) dropped).
// gl_FragCoord top-left/+0.5, NO Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D overlayTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 coord = ivec2(int(gl_FragCoord.x), int(gl_FragCoord.y));
	vec4 base = texelFetch(inputTex, coord, 0);
	vec4 overlay = texelFetch(overlayTex, coord, 0);

	float a = overlay.a * alpha;
	vec3 result = base.rgb * (1.0 - a) + overlay.rgb * a;
	frag = vec4(result, base.a);
}

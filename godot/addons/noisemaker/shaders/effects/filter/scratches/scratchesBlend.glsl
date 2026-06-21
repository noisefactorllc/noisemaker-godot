#version 450
// filter/scratches program "scratchesBlend" — ported from wgsl/scratchesBlend.wgsl.
// Max-composites a film-scratch overlay onto the input: result = max(base, overlay.a*alpha).
// Single render pass (progName "scratchesBlend").
//
// NOTE ON OVERLAY: the scratch overlay (`overlayTex`) is produced on the CPU by the effect's
// JS asyncInit (traceWorms → a 2D canvas), NOT by any GPU shader — there is no overlay
// program to port. In the headless parity harness (and any pipeline that drives render()
// directly) asyncInit does not run, so overlayTex is the empty/zero-cleared texture and this
// blend passes the input through unchanged (max(base, 0) == base). The GLSL below is a
// faithful port of the only GPU program; a true scratch overlay needs the CPU tracer.
//
// MULTI-INPUT, no-layout effect (scratches.json has NO uniformLayout). Two inputs in
// pass.inputs order: inputTex = base (binding 1), overlayTex = CPU overlay (binding 2). The
// backend SYNTHESIZES the Params UBO + `#define <name> data[slot].comp`; the pass wires
// uniforms.alpha = `alpha`, so the bare name is `alpha`.
//
// WGSL→GLSL: textureLoad(t,coord,0)→texelFetch(t,coord,0) (integer coords, no sampler — the
// WGSL deliberately uses textureLoad; the dead binding(0) sampler is dropped). gl_FragCoord
// is top-left/+0.5 like @position — NO Y-flip.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D overlayTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	ivec2 coord = ivec2(int(gl_FragCoord.x), int(gl_FragCoord.y));
	vec4 base = texelFetch(inputTex, coord, 0);
	vec4 overlay = texelFetch(overlayTex, coord, 0);

	float scratchStrength = overlay.a * alpha;
	vec3 result = max(base.rgb, vec3(scratchStrength));
	frag = vec4(result, base.a);
}

#version 450
// filter/outline program "outlineBlend" — ported from wgsl/outlineBlend.wgsl.
// Pass 3 of 3: composite the edge stroke onto the base. Edge strength comes from
// the edges texture's red channel; the stroke is black (default) or white
// (invert). out = mix(base, outlineColor, strength).
// No-layout effect: backend injects the Params UBO + engine globals. Two inputs
// (pass.inputs order): inputTex = original scene (binding 1), edgesTexture =
// outlineEdges (binding 2). Backend sampler is NEAREST + clamp, so sampling at
// gl_FragCoord.xy/texSize reads the exact texel — matching the WGSL
// textureSample(texCoord) pass-through.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D edgesTexture;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	vec4 base = texture(inputTex, uv);
	vec4 edges = texture(edgesTexture, uv);

	// Edge strength from luminance
	float strength = clamp(edges.r, 0.0, 1.0);

	// Outline color: black by default, white if inverted
	vec3 outlineColor = invert > 0.5 ? vec3(1.0) : vec3(0.0);

	// Apply outline where edges are present
	vec3 out_rgb = mix(base.rgb, outlineColor, strength);

	frag = vec4(out_rgb, base.a);
}

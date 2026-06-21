#version 450
// synth/navierStokes — program "ns" (display / composite). Ported from glsl/ns.glsl, taking
// the WGSL ns.wgsl form for coordinates: the reference GLSL reads engine globals tileOffset
// and fullResolution, but in this Godot backend tileOffset == (0,0) and fullResolution ==
// resolution (== screen), and the navierStokes.json layout for "ns" maps ONLY resolution and
// inputIntensity. So globalCoord -> gl_FragCoord.xy and fullResolution -> resolution, which
// is numerically identical and matches the WGSL port. Plain bilinear blit of the dye (.b)
// channel of the full-res smoothed canvas, then optional input-texture blend. The smoothed
// canvas (global_ns_smoothed) is bound NEAREST + clamp-to-edge, so texelFetch fetches exact
// texels (== WGSL textureLoad). No deltaTime / engine-global packing needed beyond the layout.
//
// Layout effect: vec4 data[2] (effects/synth/navierStokes.json, uniformLayouts.ns):
//   resolution = data[0].xy, inputIntensity = data[1].x.
// Inputs (pass.inputs order): fbTex = binding 1 (smoothed state), inputTex = binding 2.
// gl_FragCoord top-left, +0.5 — NO Y-flip.
#include "include/nm_core.glsl"

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[2]; };
layout(set = 0, binding = 1) uniform sampler2D fbTex;
layout(set = 0, binding = 2) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 resolution = data[0].xy;
	float inputIntensity = data[1].x;

	ivec2 texSize = textureSize(fbTex, 0);
	ivec2 minIdx = ivec2(0);
	ivec2 maxIdx = texSize - ivec2(1);

	vec2 texelPos = (gl_FragCoord.xy * vec2(texSize) / resolution) - vec2(0.5);
	ivec2 baseI = ivec2(floor(texelPos));
	vec2 f = fract(texelPos);

	float v00 = texelFetch(fbTex, clamp(baseI,                 minIdx, maxIdx), 0).b;
	float v10 = texelFetch(fbTex, clamp(baseI + ivec2(1, 0),   minIdx, maxIdx), 0).b;
	float v01 = texelFetch(fbTex, clamp(baseI + ivec2(0, 1),   minIdx, maxIdx), 0).b;
	float v11 = texelFetch(fbTex, clamp(baseI + ivec2(1, 1),   minIdx, maxIdx), 0).b;

	float v0 = mix(v00, v10, f.x);
	float v1 = mix(v01, v11, f.x);
	float state = mix(v0, v1, f.y);

	float intensity = clamp(state, 0.0, 1.0);
	vec3 outCol = vec3(intensity);

	float blend = clamp(inputIntensity, 0.0, 100.0) * 0.01;
	if (blend > 0.0) {
		vec2 inputUv = gl_FragCoord.xy / resolution;
		vec3 inputColor = texture(inputTex, inputUv).rgb;
		outCol = mix(outCol, inputColor, blend);
	}

	frag = vec4(outCol, 1.0);
}

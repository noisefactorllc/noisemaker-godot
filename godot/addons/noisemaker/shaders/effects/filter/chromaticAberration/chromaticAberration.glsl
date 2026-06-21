#version 450
// filter/chromaticAberration — ported from wgsl/chromaticAberration.wgsl.
// Color fringing effect simulating lens aberration. Single render pass: the
// R/G/B channels are sampled at slightly offset UVs and recombined.
// No-layout effect: the backend injects the Params UBO + `#define aberrationAmt …`/
// `#define passthru …` (synthesized layout) and engine globals (tileOffset,
// fullResolution), so we use the bare reference names directly. Input texture
// bound at set 0, binding 1.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;

// mapVal — verbatim from WGSL mapVal(value, inMin, inMax, outMin, outMax).
float mapVal(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

void main() {
	// NOTE: local renamed `aspectRatio`->`ar`; `aspectRatio` is an injected
	// engine `#define` (data[0].w), so reusing the name breaks the preprocessor.
	float ar = fullResolution.x / fullResolution.y;
	vec2 uv = (gl_FragCoord.xy + tileOffset) / fullResolution;
	vec2 texSize = vec2(textureSize(inputTex, 0));

	vec2 diff = vec2(0.5 * ar, 0.5) - vec2(uv.x * ar, uv.y);
	float centerDist = length(diff);

	float aberrationOffset = mapVal(aberrationAmt, 0.0, 100.0, 0.0, 0.05) * centerDist * PI * 0.5;

	float redOffset = mix(clamp(uv.x + aberrationOffset, 0.0, 1.0), uv.x, uv.x);
	vec4 red = texture(inputTex, (vec2(redOffset, uv.y) * fullResolution - tileOffset) / texSize);

	vec4 green = texture(inputTex, gl_FragCoord.xy / texSize);

	float blueOffset = mix(uv.x, clamp(uv.x - aberrationOffset, 0.0, 1.0), uv.x);
	vec4 blue = texture(inputTex, (vec2(blueOffset, uv.y) * fullResolution - tileOffset) / texSize);

	// chromatic aberration - extract color fringing edges only
	vec3 aberrated = vec3(red.r, green.g, blue.b);
	vec3 edges = aberrated - green.rgb;

	// scale original by passthru and add to edges
	vec3 original = green.rgb * mapVal(passthru, 0.0, 100.0, 0.0, 2.0);

	frag = vec4(min(edges + original, vec3(1.0)), green.a);
}

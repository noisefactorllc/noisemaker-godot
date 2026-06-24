#version 450
// render/pointsRender — program "blend" (composite the accumulated trail over the chained
// input). Ported from glsl/blend.glsl. Trail is added on top; input is scaled by
// inputIntensity and matte opacity; alpha = max(trail presence, matte).
// Layout effect: vec4 data[1] (uniformLayouts.blend): resolution=data[0].xy,
// inputIntensity=data[0].z, matteOpacity=data[0].w. Inputs: inputTex=1, trailTex=2.
// gl_FragCoord top-left — NO Y-flip.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
#define resolution data[0].xy
#define inputIntensity data[0].z
#define matteOpacity data[0].w
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D trailTex;
layout(location = 0) out vec4 fragColor;
layout(location = 0) in vec2 v_uv;

void main() {
	vec2 uv = gl_FragCoord.xy / resolution;

	vec4 inputColor = texture(inputTex, uv);
	vec4 trailColor = texture(trailTex, uv);

	// Additive blend: trail + scaled input
	// inputIntensity 0 = black, 100 = trail + full input
	float t = inputIntensity / 100.0;
	float matteAlpha = matteOpacity;

	// Trail presence based on max RGB channel
	float trailPresence = max(max(trailColor.r, trailColor.g), trailColor.b);

	// Background contribution is scaled by matte opacity (premultiplied)
	// Trail contribution is NOT affected by matte opacity
	vec3 rgb = trailColor.rgb + inputColor.rgb * t * matteAlpha;

	// Alpha: where trail exists, full opacity; elsewhere, matte opacity
	float alpha = max(trailPresence, matteAlpha);

	fragColor = clamp(vec4(rgb, alpha), 0.0, 1.0);
}

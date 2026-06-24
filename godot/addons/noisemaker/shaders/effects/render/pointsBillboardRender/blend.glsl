#version 450
// render/pointsBillboardRender — program "blend" (composite the billboard trail OVER the
// chained input). Ported from glsl/blend.glsl. The deposit pass runs in one of two blend
// modes (blendMode: additive=0 / alpha=1); the blend pass un-premultiplies accordingly.
// Layout effect: vec4 data[1] (uniformLayouts.blend): resolution=data[0].xy,
// inputIntensity=data[0].z, blendMode=data[0].w. Inputs: inputTex=1, trailTex=2.
// gl_FragCoord top-left — NO Y-flip.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
#define resolution data[0].xy
#define inputIntensity data[0].z
#define blendMode int(data[0].w)
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D trailTex;
layout(location = 0) out vec4 fragColor;
layout(location = 0) in vec2 v_uv;

void main() {
	vec2 uv = gl_FragCoord.xy / resolution;

	vec4 inputColor = texture(inputTex, uv);
	vec4 trailColor = texture(trailTex, uv);

	// Blend: trail over scaled input using alpha
	// inputIntensity 0 = trail only, 100 = trail over full input
	float t = inputIntensity / 100.0;
	vec4 scaledInput = inputColor * t;

	vec3 outRGB;
	float outAlpha;

	if (blendMode == 1) {
		// Alpha mode: trail stores premultiplied values (rgb = actual_color * alpha).
		// Use premultiplied OVER operator then convert to straight for output.
		outAlpha = trailColor.a + scaledInput.a * (1.0 - trailColor.a);
		vec3 outRGB_pre = trailColor.rgb + scaledInput.rgb * scaledInput.a * (1.0 - trailColor.a);
		outRGB = outAlpha > 0.0 ? outRGB_pre / outAlpha : vec3(0.0);
	} else {
		// Additive mode: trail stores additive sums; treat as pseudo-non-premultiplied.
		outAlpha = trailColor.a + scaledInput.a * (1.0 - trailColor.a);
		outRGB = outAlpha > 0.0
			? (trailColor.rgb * trailColor.a + scaledInput.rgb * scaledInput.a * (1.0 - trailColor.a)) / outAlpha
			: vec3(0.0);
	}

	fragColor = clamp(vec4(outRGB, outAlpha), 0.0, 1.0);
}

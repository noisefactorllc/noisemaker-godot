#version 450
// filter/blurV — ported from wgsl/blurV.wgsl. Vertical separable Gaussian blur.
// No-layout effect: backend injects Params UBO + `#define radiusX …`/`radiusY …`
// and engine globals. Input texture bound at set 0, binding 1 (pass.inputs order).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec2 texelSize = 1.0 / texSize;

	int radius = int(radiusY);
	if (radius <= 0) {
		frag = texture(inputTex, uv);
		return;
	}

	float sigma = float(radius) / 3.0;
	float sigma2 = sigma * sigma;

	vec4 sum = vec4(0.0);
	float weightSum = 0.0;

	for (int i = -radius; i <= radius; i = i + 1) {
		float x = float(i);
		float weight = exp(-(x * x) / (2.0 * sigma2));
		vec2 offset = vec2(0.0, float(i) * texelSize.y);
		sum = sum + texture(inputTex, uv + offset) * weight;
		weightSum = weightSum + weight;
	}

	frag = sum / weightSum;
}

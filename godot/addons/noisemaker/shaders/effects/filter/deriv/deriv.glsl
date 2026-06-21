#version 450
// filter/deriv — ported from wgsl/deriv.wgsl. Derivative-based edge detection.
// Samples neighbours offset by `amount` texels, desaturates, computes dx/dy
// differences, multiplies the original color by the Euclidean distance * 2.5.
// No-layout effect: backend injects Params UBO + `amount` and engine globals.
// Input texture bound at set 0, binding 1 (pass.inputs order).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// desaturate — ported VERBATIM from deriv.wgsl (this effect's own helper).
vec3 desaturate(vec3 color) {
	float avg = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
	return vec3(avg);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec2 texelSize = 1.0 / texSize;

	vec4 color = texture(inputTex, uv);

	// Sample neighbors for derivative calculation
	vec3 center = desaturate(color.rgb);
	vec3 right = desaturate(texture(inputTex, uv + vec2(texelSize.x * amount, 0.0)).rgb);
	vec3 bottom = desaturate(texture(inputTex, uv + vec2(0.0, texelSize.y * amount)).rgb);

	// Compute derivatives
	vec3 dx = center - right;
	vec3 dy = center - bottom;

	float dist = distance(dx, dy) * 2.5;

	frag = vec4(clamp(color.rgb * dist, vec3(0.0), vec3(1.0)), color.a);
}

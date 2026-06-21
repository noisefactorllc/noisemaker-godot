#version 450
// filter/sobel — ported PIXEL-IDENTICALLY from wgsl/sobel.wgsl. Classic Sobel
// operator for edge detection (3x3 convolution over neighbor texels).
// No-layout effect: the backend synthesizes the Params UBO + `#define amount …`/
// `#define alpha …` (one per globals[*].uniform) and the engine globals, so we use
// the bare reference names directly. Input texture bound at set 0, binding 1.
//
// uv divides by the INPUT texture size (textureSize), NOT fullResolution — mirrored
// from the WGSL exactly. gl_FragCoord is top-left (+0.5 centered) like the WGSL @position,
// so NO per-effect Y-flip (the WGSL has none; the single present flip handles orientation).
//
// `texelSize`, the sobel_x/sobel_y kernel weights, and the offset signs are reproduced
// EXACTLY — sobel is a convolution and any change to offsets/weights breaks parity.
//
// PARITY TOLERANCE (logged per PORTING-GUIDE §"Per-effect checklist" 5):
//   sobel is a contrast convolution like `edge`: it sums neighbor differences over a 3x3
//   window via two gradient kernels and takes distance(convX, convY). Cross-device
//   half-float/transcendental residuals in the upstream input can magnify to ±1 LSB at
//   the steepest-gradient pixels. The sobel formula itself is bit-faithful to sobel.wgsl;
//   loosen tolerance only for this amplifying-convolution case and log it.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;
	vec2 texelSize = 1.0 / texSize;

	vec4 origColor = texture(inputTex, uv);

	// Sobel X and Y kernels
	float sobel_x[9] = float[9](1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0);
	float sobel_y[9] = float[9](1.0, 2.0, 1.0, 0.0, 0.0, 0.0, -1.0, -2.0, -1.0);

	vec2 offsets[9] = vec2[9](
		vec2(-texelSize.x, -texelSize.y),
		vec2(0.0, -texelSize.y),
		vec2(texelSize.x, -texelSize.y),
		vec2(-texelSize.x, 0.0),
		vec2(0.0, 0.0),
		vec2(texelSize.x, 0.0),
		vec2(-texelSize.x, texelSize.y),
		vec2(0.0, texelSize.y),
		vec2(texelSize.x, texelSize.y)
	);

	vec3 convX = vec3(0.0);
	vec3 convY = vec3(0.0);

	for (int i = 0; i < 9; i = i + 1) {
		vec3 s = texture(inputTex, uv + offsets[i] * amount).rgb;
		convX = convX + s * sobel_x[i];
		convY = convY + s * sobel_y[i];
	}

	float dist = distance(convX, convY);

	// Multiply with original color
	vec3 result = origColor.rgb * dist;

	// Blend between original input and sobel result
	vec3 blended = mix(origColor.rgb, result, alpha);

	frag = vec4(blended, origColor.a);
}

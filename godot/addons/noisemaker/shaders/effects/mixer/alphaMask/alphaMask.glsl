#version 450
// mixer/alphaMask — ported from wgsl/alphaMask.wgsl. Alpha transparency blend of
// two surfaces. No-layout effect: backend injects Params UBO + `#define mixAmt …`/
// `maskMode …`. Two inputs (pass.inputs order): inputTex = base (binding 1),
// tex = layer (binding 2). map_range is this effect's own per-effect copy.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float map_range(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 st = gl_FragCoord.xy / dims;

	vec4 color1 = texture(inputTex, st);
	vec4 color2 = texture(tex, st);

	// luminance mask mode
	if (int(maskMode) != 0) {
		float maskVal = dot(color2.rgb, vec3(0.299, 0.587, 0.114));
		frag = vec4(color1.rgb, color1.a * maskVal);
		return;
	}

	// alpha blend. slider direction selects which input is on top, so either slot
	// can serve as the alpha source — slide negative for A-on-top, positive for
	// B-on-top. each half reaches a full Porter-Duff source-over at the midpoint.
	vec4 color;
	if (mixAmt < 0.0) {
		vec4 AoverB = color2 * (1.0 - color1.a) + color1 * color1.a;
		color = mix(color1, AoverB, map_range(mixAmt, -100.0, 0.0, 0.0, 1.0));
	} else {
		vec4 BoverA = color1 * (1.0 - color2.a) + color2 * color2.a;
		color = mix(BoverA, color2, map_range(mixAmt, 0.0, 100.0, 0.0, 1.0));
	}

	color.a = max(color1.a, color2.a);
	frag = color;
}

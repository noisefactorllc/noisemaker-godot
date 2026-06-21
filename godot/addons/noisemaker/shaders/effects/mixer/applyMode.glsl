#version 450
// mixer/applyMode — ported from wgsl/applyMode.wgsl. Apply brightness, hue, or
// saturation from source B onto source A, then cross-fade with `mixAmt`.
// No-layout effect: backend injects Params UBO + `#define mode …`/`mixAmt …`.
// Two inputs (pass.inputs order): inputTex = base A (binding 1), tex = blend B (binding 2).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float map_range(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p;
	if (c.b > c.g) {
		p = vec4(c.b, c.g, K.w, K.z);
	} else {
		p = vec4(c.g, c.b, K.x, K.y);
	}
	vec4 q;
	if (p.x > c.r) {
		q = vec4(p.x, p.y, p.w, c.r);
	} else {
		q = vec4(c.r, p.y, p.z, p.x);
	}
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, vec3(0.0), vec3(1.0)), c.y);
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 st = gl_FragCoord.xy / dims;

	vec4 color1 = texture(inputTex, st);
	vec4 color2 = texture(tex, st);

	vec3 a = rgb2hsv(color1.rgb);
	vec3 b = rgb2hsv(color2.rgb);
	vec3 resultHSV;

	if (int(mode) == 0) {
		// brightness: hue/sat from A, value from B
		resultHSV = vec3(a.x, a.y, b.z);
	} else if (int(mode) == 1) {
		// hue: hue from B, sat/value from A
		resultHSV = vec3(b.x, a.y, a.z);
	} else {
		// saturation: hue/value from A, saturation from B
		resultHSV = vec3(a.x, b.y, a.z);
	}

	vec4 middle = vec4(hsv2rgb(resultHSV), 1.0);

	float amt = map_range(mixAmt, -100.0, 100.0, 0.0, 1.0);
	vec4 color;
	if (amt < 0.5) {
		float factor = amt * 2.0;
		color = mix(color1, middle, factor);
	} else {
		float factor = (amt - 0.5) * 2.0;
		color = mix(middle, color2, factor);
	}

	color.a = max(color1.a, color2.a);
	frag = color;
}

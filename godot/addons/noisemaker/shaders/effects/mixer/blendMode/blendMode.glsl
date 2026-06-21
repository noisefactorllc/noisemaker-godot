#version 450
// mixer/blendMode — ported from wgsl/blendMode.wgsl. 16 blend modes + mix + Porter-Duff
// "over". No-layout effect: backend injects Params UBO + `#define mode …`/`mixAmt …`.
// Two inputs (pass.inputs order): inputTex = base (binding 1), tex = blend (binding 2).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

float map_range(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float blendOverlay(float a, float b) {
	if (a < 0.5) {
		return 2.0 * a * b;
	} else {
		return 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
	}
}

float blendSoftLight(float base, float blend) {
	if (blend < 0.5) {
		return 2.0 * base * blend + base * base * (1.0 - 2.0 * blend);
	} else {
		return sqrt(base) * (2.0 * blend - 1.0) + 2.0 * base * (1.0 - blend);
	}
}

vec4 applyBlendMode(vec4 color1, vec4 color2, int m) {
	if (m == 0) { return min(color1 + color2, vec4(1.0)); }
	if (m == 1) { return 1.0 - min((1.0 - color1) / max(color2, vec4(0.001)), vec4(1.0)); }
	if (m == 2) { return min(color1, color2); }
	if (m == 3) { return abs(color1 - color2); }
	if (m == 4) { return min(color1 / max(1.0 - color2, vec4(0.001)), vec4(1.0)); }
	if (m == 5) { return color1 + color2 - 2.0 * color1 * color2; }
	if (m == 6) {
		return vec4(blendOverlay(color2.r, color1.r), blendOverlay(color2.g, color1.g),
			blendOverlay(color2.b, color1.b), 1.0);
	}
	if (m == 7) { return max(color1, color2); }
	if (m == 8) { return (color1 + color2) * 0.5; }
	if (m == 9) { return color1 * color2; }
	if (m == 10) { return vec4(1.0) - abs(vec4(1.0) - color1 - color2); }
	if (m == 11) {
		return vec4(blendOverlay(color1.r, color2.r), blendOverlay(color1.g, color2.g),
			blendOverlay(color1.b, color2.b), 1.0);
	}
	if (m == 12) { return min(color1, color2) - max(color1, color2) + vec4(1.0); }
	if (m == 13) { return vec4(1.0) - (vec4(1.0) - color1) * (vec4(1.0) - color2); }
	if (m == 14) {
		return vec4(blendSoftLight(color1.r, color2.r), blendSoftLight(color1.g, color2.g),
			blendSoftLight(color1.b, color2.b), 1.0);
	}
	return max(color1 - color2, vec4(0.0));
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 st = gl_FragCoord.xy / dims;

	vec4 color1 = texture(inputTex, st);
	vec4 color2 = texture(tex, st);

	int m = int(mode);
	vec4 middle = applyBlendMode(color1, color2, m);

	float amt = map_range(mixAmt, -100.0, 100.0, 0.0, 1.0);
	vec4 color;
	if (amt < 0.5) {
		float factor = amt * 2.0;
		color = mix(color1, middle, factor);
	} else {
		float factor = (amt - 0.5) * 2.0;
		color = mix(middle, color2, factor);
	}

	float alphaFactor = color2.a * amt;
	color = vec4(mix(color1.rgb, color.rgb, color2.a), alphaFactor + color1.a * (1.0 - alphaFactor));
	frag = color;
}

#version 450
// classicNoisedeck/coalesce — ported PIXEL-IDENTICALLY from wgsl/coalesce.wgsl. Composites
// two inputs under ~25 blend modes, each cross-refracted by the other's luminance, plus a
// "cloak" refractive cross-mix mode. Single render pass (progName "coalesce").
//
// MULTI-INPUT, no-layout effect (coalesce.json has NO uniformLayout). Two inputs in
// pass.inputs order: inputTex = first feed (binding 1), tex = second feed (binding 2). The
// WGSL had a sampler `samp` at binding 1 then textures at bindings 2/3; Godot uses combined
// sampler2D inputTex@1 and tex@2. The backend SYNTHESIZES the Params UBO + `#define <name>
// data[slot].comp` for the params; use bare names. The pass wires uniforms.mixAmt = `mix`
// (global key `mix`, uniform alias `mixAmt`), so the bare name is `mixAmt` (the WGSL's
// binding name). Other params: blendMode, refractAAmt, refractBAmt, refractADir, refractBDir.
// No reserved-name collisions among helpers/locals.
//
// COORDINATE NOTE: ported from WGSL (top-left). st = gl_FragCoord.xy / textureSize(inputTex).
// NO Y-flip. textureSample -> texture; textureDimensions -> textureSize; WGSL float `%` ->
// GLSL `mod`; `select(a,b,c)` -> `c ? b : a`; `all(a==b)` -> `all(equal(a,b))`.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float CO_PI = 3.14159265359;
const float CO_TAU = 6.28318530718;

float map_range(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float blendOverlay(float a, float b) {
	if (a < 0.5) {
		return 2.0 * a * b;
	}
	return 1.0 - 2.0 * (1.0 - a) * (1.0 - b);
}

float blendSoftLight(float base, float blend) {
	if (blend < 0.5) {
		return 2.0 * base * blend + base * base * (1.0 - 2.0 * blend);
	}
	return sqrt(base) * (2.0 * blend - 1.0) + 2.0 * base * (1.0 - blend);
}

vec4 cloak(vec2 st) {
	float m = map_range(mixAmt, -100.0, 100.0, 0.0, 1.0);
	float ra = map_range(refractAAmt, 0.0, 100.0, 0.0, 0.125);
	float rb = map_range(refractBAmt, 0.0, 100.0, 0.0, 0.125);

	vec4 leftColor = texture(inputTex, st);
	vec4 rightColor = texture(tex, st);

	// When the mixer is all the way to the left, we see left refracted by right
	vec2 leftUV = st;
	float rightLen = length(rightColor.rgb);
	leftUV.x = leftUV.x + cos(rightLen * CO_TAU) * ra;
	leftUV.y = leftUV.y + sin(rightLen * CO_TAU) * ra;

	vec4 leftRefracted = texture(inputTex, fract(leftUV));

	// When the mixer is all the way to the right, we see right refracted by left
	vec2 rightUV = st;
	float leftLen = length(leftColor.rgb);
	rightUV.x = rightUV.x + cos(leftLen * CO_TAU) * rb;
	rightUV.y = rightUV.y + sin(leftLen * CO_TAU) * rb;

	vec4 rightRefracted = texture(tex, fract(rightUV));

	// As the mixer approaches midpoint, mix the two refracted outputs using the same
	// logic as the "reflect" mode in coalesce.
	vec4 leftReflected = min(rightRefracted * rightColor / (1.0 - leftRefracted * leftColor), vec4(1.0));
	vec4 rightReflected = min(leftRefracted * leftColor / (1.0 - rightRefracted * rightColor), vec4(1.0));

	vec4 left = vec4(1.0);
	vec4 right = vec4(1.0);
	if (mixAmt < 0.0) {
		left = mix(leftRefracted, leftReflected, map_range(mixAmt, -100.0, 0.0, 0.0, 1.0));
		right = rightReflected;
	} else {
		left = leftReflected;
		right = mix(rightReflected, rightRefracted, map_range(mixAmt, 0.0, 100.0, 0.0, 1.0));
	}

	return mix(left, right, m);
}

vec3 hsv2rgb(vec3 hsv) {
	float h = fract(hsv.x);
	float s = hsv.y;
	float v = hsv.z;

	float c = v * s;
	float x = c * (1.0 - abs(mod(h * 6.0, 2.0) - 1.0));
	float m = v - c;

	vec3 rgb;

	if (h < 1.0 / 6.0) {
		rgb = vec3(c, x, 0.0);
	} else if (h < 2.0 / 6.0) {
		rgb = vec3(x, c, 0.0);
	} else if (h < 3.0 / 6.0) {
		rgb = vec3(0.0, c, x);
	} else if (h < 4.0 / 6.0) {
		rgb = vec3(0.0, x, c);
	} else if (h < 5.0 / 6.0) {
		rgb = vec3(x, 0.0, c);
	} else {
		rgb = vec3(c, 0.0, x);
	}

	return rgb + vec3(m, m, m);
}

vec3 rgb2hsv(vec3 rgb) {
	float r = rgb.r;
	float g = rgb.g;
	float b = rgb.b;

	float max_val = max(r, max(g, b));
	float min_val = min(r, min(g, b));
	float delta = max_val - min_val;

	float h = 0.0;
	if (delta != 0.0) {
		if (max_val == r) {
			h = mod((g - b) / delta, 6.0) / 6.0;
		} else if (max_val == g) {
			h = ((b - r) / delta + 2.0) / 6.0;
		} else if (max_val == b) {
			h = ((r - g) / delta + 4.0) / 6.0;
		}
	}

	float s = 0.0;
	if (max_val != 0.0) {
		s = delta / max_val;
	}
	float v = max_val;

	return vec3(h, s, v);
}

bool vec4_eq(vec4 a, vec4 b) {
	return all(equal(a, b));
}

vec3 blend_colors(vec4 color1, vec4 color2, int mode, float factor_in) {
	vec4 color;
	vec4 middle;

	float amt = map_range(mixAmt, -100.0, 100.0, 0.0, 1.0);
	float factor = factor_in;

	vec4 a = vec4(1.0);
	vec4 b = vec4(1.0);
	if (mode >= 1000) {
		a = vec4(rgb2hsv(color1.rgb), color1.a);
		b = vec4(rgb2hsv(color2.rgb), color2.a);
	}

	if (mode == 0) {
		// add
		middle = min(color1 + color2, vec4(1.0));
	} else if (mode == 1) {
		// alpha
		if (mixAmt < 0.0) {
			return mix(color1,
					   color2 * vec4(1.0 - color1.a) + color1 * vec4(color1.a),
					   map_range(mixAmt, -100.0, 0.0, 0.0, 1.0)).rgb;
		} else {
			return mix(color1 * vec4(1.0 - color2.a) + color2 * vec4(color2.a),
					   color2,
					   map_range(mixAmt, 0.0, 100.0, 0.0, 1.0)).rgb;
		}
	} else if (mode == 2) {
		// color burn
		if (vec4_eq(color2, vec4(0.0))) {
			middle = color2;
		} else {
			middle = max((1.0 - ((1.0 - color1) / color2)), vec4(0.0));
		}
	} else if (mode == 3) {
		// color dodge
		if (vec4_eq(color2, vec4(1.0))) {
			middle = color2;
		} else {
			middle = min(color1 / (1.0 - color2), vec4(1.0));
		}
	} else if (mode == 4) {
		// darken
		middle = min(color1, color2);
	} else if (mode == 5) {
		// difference
		middle = abs(color1 - color2);
	} else if (mode == 6) {
		// exclusion
		middle = color1 + color2 - 2.0 * color1 * color2;
	} else if (mode == 7) {
		// glow
		if (vec4_eq(color2, vec4(1.0))) {
			middle = color2;
		} else {
			middle = min(color1 * color1 / (1.0 - color2), vec4(1.0));
		}
	} else if (mode == 8) {
		// hard light
		middle = vec4(blendOverlay(color2.r, color1.r), blendOverlay(color2.g, color1.g), blendOverlay(color2.b, color1.b), mix(color1.a, color2.a, 0.5));
	} else if (mode == 9) {
		// lighten
		middle = max(color1, color2);
	} else if (mode == 10) {
		// mix
		middle = mix(color1, color2, 0.5);
	} else if (mode == 11) {
		// multiply
		middle = color1 * color2;
	} else if (mode == 12) {
		// negation
		middle = vec4(1.0) - abs(vec4(1.0) - color1 - color2);
	} else if (mode == 13) {
		// overlay
		middle = vec4(blendOverlay(color1.r, color2.r), blendOverlay(color1.g, color2.g), blendOverlay(color1.b, color2.b), mix(color1.a, color2.a, 0.5));
	} else if (mode == 14) {
		// phoenix
		middle = min(color1, color2) - max(color1, color2) + vec4(1.0);
	} else if (mode == 15) {
		// reflect
		if (vec4_eq(color1, vec4(1.0))) {
			middle = color1;
		} else {
			middle = min(color2 * color2 / (1.0 - color1), vec4(1.0));
		}
	} else if (mode == 16) {
		// screen
		middle = 1.0 - ((1.0 - color1) * (1.0 - color2));
	} else if (mode == 17) {
		// soft light
		middle = vec4(blendSoftLight(color1.r, color2.r), blendSoftLight(color1.g, color2.g), blendSoftLight(color1.b, color2.b), mix(color1.a, color2.a, 0.5));
	} else if (mode == 18) {
		// subtract
		middle = max(color1 + color2 - 1.0, vec4(0.0));
	} else if (mode == 1000) {
		// hue a->b
		middle = vec4(hsv2rgb(vec3(b.r, a.g, a.b)), 1.0);
	} else if (mode == 1001) {
		// hue b->a
		middle = vec4(hsv2rgb(vec3(a.r, b.g, b.b)), 1.0);
	} else if (mode == 1002) {
		// saturation a->b
		middle = vec4(hsv2rgb(vec3(a.r, b.g, a.b)), 1.0);
	} else if (mode == 1003) {
		// saturation b->a
		middle = vec4(hsv2rgb(vec3(b.r, a.g, b.b)), 1.0);
	} else if (mode == 1004) {
		// brightness a->b
		middle = vec4(hsv2rgb(vec3(a.r, a.g, b.b)), 1.0);
	} else {
		// brightness b->a (mode == 1005)
		middle = vec4(hsv2rgb(vec3(b.r, b.g, a.b)), 1.0);
	}

	if (mode >= 1000) {
		middle.a = mix(color1.a, color2.a, 0.5);
	}

	if (factor == 0.5) {
		color = middle;
	} else if (factor < 0.5) {
		factor = map_range(amt, 0.0, 0.5, 0.0, 1.0);
		color = mix(color1, middle, factor);
	} else {
		factor = map_range(amt, 0.5, 1.0, 0.0, 1.0);
		color = mix(middle, color2, factor);
	}

	return color.rgb;
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 st = gl_FragCoord.xy / dims;

	vec4 color = vec4(0.0, 0.0, 1.0, 1.0);

	if (blendMode == 100) {
		color = cloak(st);
	} else {
		float ra = map_range(refractAAmt, 0.0, 100.0, 0.0, 0.125);
		float rb = map_range(refractBAmt, 0.0, 100.0, 0.0, 0.125);

		vec4 leftColor = texture(inputTex, st);
		vec4 rightColor = texture(tex, st);

		// refract a->b
		vec2 leftUV = st;
		float rightLen = length(rightColor.rgb) + refractADir / 360.0;
		leftUV.x = leftUV.x + cos(rightLen * CO_TAU) * ra;
		leftUV.y = leftUV.y + sin(rightLen * CO_TAU) * ra;

		// refract b->a
		vec2 rightUV = st;
		float leftLen = length(leftColor.rgb) + refractBDir / 360.0;
		rightUV.x = rightUV.x + cos(leftLen * CO_TAU) * rb;
		rightUV.y = rightUV.y + sin(leftLen * CO_TAU) * rb;

		vec4 color1 = texture(inputTex, leftUV);
		vec4 color2 = texture(tex, rightUV);

		// blendMode is an int param but arrives as a float UBO component (synth #define) —
		// narrow at the call site for the int `mode` parameter.
		color = vec4(blend_colors(color1, color2, int(blendMode), mixAmt), max(color1.a, color2.a));
	}

	frag = color;
}

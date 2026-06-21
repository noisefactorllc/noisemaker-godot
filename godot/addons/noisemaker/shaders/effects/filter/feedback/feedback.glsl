#version 450
// filter/feedback (program "feedback") — ported from wgsl/feedback.wgsl.
// FEEDBACK effect: blends the live `inputTex` with the prior-frame feedback buffer
// `selfTex`, applying blend modes, transforms (rotate/scale/lens/distortion),
// chromatic aberration, refraction, hue rotation and brightness/contrast.
// No-layout effect: backend injects the Params UBO + `#define blendMode …`/`mixAmt …`/
// `scaleAmt …`/… and engine globals (`resolution`, …). Inputs bind at set 0 in
// pass.inputs order: inputTex (live) = binding 1, selfTex (prior frame) = binding 2.
//
// All helpers below are this effect's OWN versions, inlined verbatim (PORTING-GUIDE
// rule 2). `aspectRatio` inside rotate2D is renamed to `aspect` — `aspectRatio` is an
// injected engine name (`#define aspectRatio data[0].w`) and would collide otherwise.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D selfTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// Floored modulo (matches GLSL mod behavior for negative values).
float floorMod(float x, float y) {
	return x - y * floor(x / y);
}

float map(float value, float inMin, float inMax, float outMin, float outMax) {
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

vec4 blend(vec4 color1, vec4 color2, int mode, float factor) {
	vec4 middle;
	float amt = map(mixAmt, 0.0, 100.0, 0.0, 1.0);

	if (mode == 0) { // add
		middle = min(color1 + color2, vec4(1.0));
	} else if (mode == 2) { // color burn
		if (all(equal(color2, vec4(0.0)))) {
			middle = color2;
		} else {
			middle = max(1.0 - ((1.0 - color1) / color2), vec4(0.0));
		}
	} else if (mode == 3) { // color dodge
		if (all(equal(color2, vec4(1.0)))) {
			middle = color2;
		} else {
			middle = min(color1 / (1.0 - color2), vec4(1.0));
		}
	} else if (mode == 4) { // darken
		middle = min(color1, color2);
	} else if (mode == 5) { // difference
		middle = abs(color1 - color2);
		middle.a = max(color1.a, color2.a);
	} else if (mode == 6) { // exclusion
		middle = color1 + color2 - 2.0 * color1 * color2;
		middle.a = max(color1.a, color2.a);
	} else if (mode == 7) { // glow
		if (all(equal(color2, vec4(1.0)))) {
			middle = color2;
		} else {
			middle = min(color1 * color1 / (1.0 - color2), vec4(1.0));
		}
	} else if (mode == 8) { // hard light
		middle = vec4(
			blendOverlay(color2.r, color1.r),
			blendOverlay(color2.g, color1.g),
			blendOverlay(color2.b, color1.b),
			mix(color1.a, color2.a, 0.5)
		);
	} else if (mode == 9) { // lighten
		middle = max(color1, color2);
	} else if (mode == 10) { // mix
		middle = mix(color1, color2, 0.5);
	} else if (mode == 11) { // multiply
		middle = color1 * color2;
	} else if (mode == 12) { // negation
		middle = vec4(1.0) - abs(vec4(1.0) - color1 - color2);
		middle.a = max(color1.a, color2.a);
	} else if (mode == 13) { // overlay
		middle = vec4(
			blendOverlay(color1.r, color2.r),
			blendOverlay(color1.g, color2.g),
			blendOverlay(color1.b, color2.b),
			mix(color1.a, color2.a, 0.5)
		);
	} else if (mode == 14) { // phoenix
		middle = min(color1, color2) - max(color1, color2) + vec4(1.0);
	} else if (mode == 15) { // reflect
		if (all(equal(color1, vec4(1.0)))) {
			middle = color1;
		} else {
			middle = min(color2 * color2 / (1.0 - color1), vec4(1.0));
		}
	} else if (mode == 16) { // screen
		middle = 1.0 - ((1.0 - color1) * (1.0 - color2));
	} else if (mode == 17) { // soft light
		middle = vec4(
			blendSoftLight(color1.r, color2.r),
			blendSoftLight(color1.g, color2.g),
			blendSoftLight(color1.b, color2.b),
			mix(color1.a, color2.a, 0.5)
		);
	} else if (mode == 18) { // subtract
		middle = max(color1 + color2 - 1.0, vec4(0.0));
	} else {
		middle = mix(color1, color2, 0.5);
	}

	vec4 color;
	if (factor == 0.5) {
		color = middle;
	} else if (factor < 0.5) {
		float f = map(amt, 0.0, 0.5, 0.0, 1.0);
		color = mix(color1, middle, f);
	} else {
		float f = map(amt, 0.5, 1.0, 0.0, 1.0);
		color = mix(middle, color2, f);
	}

	return color;
}

vec3 brightnessContrast(vec3 color) {
	float bright = map(intensity * 0.1, -100.0, 100.0, -0.5, 0.5);
	float cont = map(intensity * 0.1, -100.0, 100.0, 0.5, 1.5);
	return (color - 0.5) * cont + 0.5 + bright;
}

vec2 rotate2D(vec2 st_in, float rot) {
	float aspect = resolution.x / resolution.y;
	vec2 st = st_in;
	st.x *= aspect;
	float rotNorm = map(rot, 0.0, 360.0, 0.0, 2.0);
	float angle = rotNorm * PI;
	st -= vec2(0.5 * aspect, 0.5);
	float c = cos(angle);
	float s = sin(angle);
	st = vec2(c * st.x - s * st.y, s * st.x + c * st.y);
	st += vec2(0.5 * aspect, 0.5);
	st.x /= aspect;
	return st;
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

	return rgb + vec3(m);
}

vec3 rgb2hsv(vec3 rgb) {
	float maxC = max(rgb.r, max(rgb.g, rgb.b));
	float minC = min(rgb.r, min(rgb.g, rgb.b));
	float delta = maxC - minC;

	float h = 0.0;
	if (delta != 0.0) {
		if (maxC == rgb.r) {
			h = floorMod((rgb.g - rgb.b) / delta, 6.0) / 6.0;
		} else if (maxC == rgb.g) {
			h = ((rgb.b - rgb.r) / delta + 2.0) / 6.0;
		} else {
			h = ((rgb.r - rgb.g) / delta + 4.0) / 6.0;
		}
	}

	float s = (maxC == 0.0) ? 0.0 : delta / maxC;
	float v = maxC;

	return vec3(h, s, v);
}

vec4 getImage(vec2 st_in) {
	vec2 st = rotate2D(st_in, rotation);

	// aberration and lensing
	vec2 diff = vec2(0.5) - st;
	float centerDist = length(diff);

	float distort = 0.0;
	float zoom = 0.0;
	if (distortion < 0.0) {
		distort = map(distortion, -100.0, 0.0, -2.0, 0.0);
		zoom = map(distortion, -100.0, 0.0, 0.04, 0.0);
	} else {
		distort = map(distortion, 0.0, 100.0, 0.0, 2.0);
		zoom = map(distortion, 0.0, 100.0, 0.0, -1.0);
	}

	st = (st - diff * zoom) - diff * centerDist * centerDist * distort;

	// scale
	float scale = 100.0 / scaleAmt;
	if (scale == 0.0) {
		scale = 1.0;
	}
	st *= scale;

	// center
	st.x -= (scale * 0.5) - (0.5 - (1.0 / resolution.x * scale));
	st.y += (scale * 0.5) + (0.5 - (1.0 / resolution.y * scale)) - (scale);

	// nudge
	st += 1.0 / resolution;

	// tile
	st = fract(st);

	// chromatic aberration
	float aberrationOffset = map(aberration, 0.0, 100.0, 0.0, 0.1) * centerDist * PI * 0.5;

	// Sample selfTex directly - no Y flip needed since input.uv coordinate space
	// already matches texture storage orientation.

	float redOffset = mix(clamp(st.x + aberrationOffset, 0.0, 1.0), st.x, st.x);
	vec4 red = texture(selfTex, vec2(redOffset, st.y));

	vec4 green = texture(selfTex, st);

	float blueOffset = mix(st.x, clamp(st.x - aberrationOffset, 0.0, 1.0), st.x);
	vec4 blue = texture(selfTex, vec2(blueOffset, st.y));

	vec4 tex = vec4(red.r, green.g, blue.b, 1.0);
	tex = vec4(tex.rgb * tex.a, tex.a);

	return tex;
}

vec4 cloak(vec2 st) {
	float m = map(mixAmt, 0.0, 100.0, 0.0, 1.0);
	float ra = map(refractAAmt, 0.0, 100.0, 0.0, 0.125);
	float rb = map(refractBAmt, 0.0, 100.0, 0.0, 0.125);

	vec4 leftColor = texture(inputTex, st);
	vec4 rightColor = texture(selfTex, st);

	vec2 leftUV = st;
	float rightLen = length(rightColor.rgb);
	leftUV.x += cos(rightLen * TAU) * ra;
	leftUV.y += sin(rightLen * TAU) * ra;
	vec4 leftRefracted = texture(inputTex, fract(leftUV));

	vec2 rightUV = st;
	float leftLen = length(leftColor.rgb);
	rightUV.x += cos(leftLen * TAU) * rb;
	rightUV.y += sin(leftLen * TAU) * rb;
	vec4 rightRefracted = texture(selfTex, fract(rightUV));

	vec4 leftReflected = min(rightRefracted * rightColor / (1.0 - leftRefracted * leftColor), vec4(1.0));
	vec4 rightReflected = min(leftRefracted * leftColor / (1.0 - rightRefracted * rightColor), vec4(1.0));

	vec4 left;
	vec4 right;
	if (mixAmt < 50.0) {
		left = mix(leftRefracted, leftReflected, map(mixAmt, 0.0, 50.0, 0.0, 1.0));
		right = rightReflected;
	} else {
		left = leftReflected;
		right = mix(rightReflected, rightRefracted, map(mixAmt, 50.0, 100.0, 0.0, 1.0));
	}

	return mix(left, right, m);
}

void main() {
	vec2 uv = gl_FragCoord.xy / resolution;

	// If resetState is true, bypass feedback and return input directly
	if (int(resetState) != 0) {
		frag = texture(inputTex, uv);
		return;
	}

	vec4 color;

	if (int(blendMode) == 100) {
		color = cloak(uv);
	} else {
		float ra = map(refractAAmt, 0.0, 100.0, 0.0, 0.125);
		float rb = map(refractBAmt, 0.0, 100.0, 0.0, 0.125);

		vec4 leftColor = texture(inputTex, uv);
		vec4 rightColor = texture(selfTex, uv);

		vec2 leftUV = uv;
		float rightLen = length(rightColor.rgb) + refractADir / 360.0;
		leftUV.x += cos(rightLen * TAU) * ra;
		leftUV.y += sin(rightLen * TAU) * ra;

		vec2 rightUV = uv;
		float leftLen = length(leftColor.rgb) + refractBDir / 360.0;
		rightUV.x += cos(leftLen * TAU) * rb;
		rightUV.y += sin(leftLen * TAU) * rb;

		color = blend(texture(inputTex, leftUV), getImage(rightUV), int(blendMode), mixAmt * 0.01);
	}

	// hue rotation
	vec3 hsv = rgb2hsv(color.rgb);
	hsv.x = fract(hsv.x + map(hueRotation, -180.0, 180.0, -0.05, 0.05));
	color = vec4(hsv2rgb(hsv), color.a);

	// brightness/contrast
	color = vec4(brightnessContrast(color.rgb), color.a);

	frag = color;
}

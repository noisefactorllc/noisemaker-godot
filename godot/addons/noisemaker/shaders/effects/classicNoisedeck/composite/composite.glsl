#version 450
// classicNoisedeck/composite — ported PIXEL-IDENTICALLY from wgsl/composite.wgsl.
// Composites two inputs under keyed / splash / channel-driven blend modes (greenscreen,
// color-splash, hue/sat/value keys, psychedelic). Single render pass (progName "composite").
//
// MULTI-INPUT, no-layout effect (composite.json has NO uniformLayout). Two inputs in
// pass.inputs order: inputTex = first feed (binding 1), tex = second feed (binding 2). The
// backend SYNTHESIZES the Params UBO + `#define <name> data[slot].comp` for the params; use
// bare names. The pass wires uniforms.mixAmt = `mix`, so the bare name is `mixAmt` (the
// WGSL's binding name). Other params: inputColor (color/vec3), blendMode (int), range (float).
// `blendMode` is an int param arriving as float → int(blendMode) at the comparison sites.
//
// COORDINATE NOTE: ported from WGSL (top-left). st = gl_FragCoord.xy / textureSize(inputTex).
// NO Y-flip. textureSample→texture; textureDimensions→textureSize; WGSL float `%`→GLSL `mod`.
// `.brg`/`.gbr` swizzles port verbatim. No reserved-name collisions among helpers/locals.
//
// ⚠️ `tex` COLLISION: unlike coalesce.json (whose `tex` surface global has no `uniform` key),
// composite.json declares the `tex` surface global WITH `"uniform": "tex"`. The backend's
// no-layout synth therefore packs a `tex` slot and injects `#define tex data[3].x` right after
// the #version line — which would rewrite `uniform sampler2D tex;` into
// `uniform sampler2D data[3].x;` ("cannot redeclare a user-block member array"). `tex` is only
// ever the second input sampler in this shader (never read as a UBO scalar), so we `#undef tex`
// here — immediately after the injected defines, before the sampler decl — to neutralize the
// stray macro WITHOUT editing the .json or the backend. (The proper fix is to drop `tex`'s
// `uniform` key in composite.json to match coalesce; that is out of scope here.)
#undef tex
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

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

vec3 desaturate(vec3 color) {
	vec3 c = rgb2hsv(color);
	c.y = 0.0;
	return hsv2rgb(c);
}

vec3 blend_colors(vec3 color1_in, vec3 color2_in) {
	vec3 color = vec3(0.0);
	vec3 color1 = color1_in;
	vec3 color2 = color2_in;
	float cut = range * 0.01;

	int mode = int(blendMode);

	if (mode == 0) {
		// color splash. isolate input color and desaturate others
		if (distance(inputColor, color1) > range * 0.01) {
			color1 = desaturate(color1);
		}

		if (distance(inputColor, color2) > range * 0.01) {
			color2 = desaturate(color2);
		}

		color = mix(color1, color2, mixAmt * 0.01);
	} else if (mode == 1) {
		// greenscreen a -> b. make color transparent
		if (distance(inputColor, color1) <= range * 0.01) {
			color = color2;
		} else {
			color = mix(color1, color2, mixAmt * 0.01);
		}
	} else if (mode == 2) {
		// greenscreen b-> a. make color transparent
		if (distance(inputColor, color2) <= range * 0.01) {
			color = color1;
		} else {
			color = mix(color2, color1, mixAmt * 0.01);
		}
	} else if (mode == 3) {
		// a -> b black
		float c = 1.0 - step(cut, desaturate(color2).r);
		color2 = mix(color1, vec3(0.0), c);
		color = mix(color1, color2, mixAmt * 0.01);
	} else if (mode == 4) {
		// a -> b color black
		vec3 c = 1.0 - step(vec3(cut), color2);
		color2 = mix(color1, vec3(0.0), c);
		color = mix(color1, color2, mixAmt * 0.01);
	} else if (mode == 5) {
		// a -> b hue
		float c = rgb2hsv(color2).r;
		color2 = mix(color1, color2, c * cut);
		color = mix(color1, color2, mixAmt * 0.01);
	} else if (mode == 6) {
		// a -> b saturation
		float c = rgb2hsv(color2).g;
		color2 = mix(color1, color2, c * cut);
		color = mix(color1, color2, mixAmt * 0.01);
	} else if (mode == 7) {
		// a -> b value
		float c = rgb2hsv(color2).b;
		color2 = mix(color1, color2, c * cut);
		color = mix(color1, color2, mixAmt * 0.01);
	} else if (mode == 8) {
		// b -> a black
		float c = 1.0 - step(cut, desaturate(color1).r);
		color1 = mix(color2, vec3(0.0), c);
		color = mix(color2, color1, mixAmt * 0.01);
	} else if (mode == 9) {
		// b -> a color black
		vec3 c = 1.0 - step(vec3(cut), color1);
		color1 = mix(color2, vec3(0.0), c);
		color = mix(color2, color1, mixAmt * 0.01);
	} else if (mode == 10) {
		// b -> a hue
		float c = rgb2hsv(color1).r;
		color1 = mix(color1, color2, c * cut);
		color = mix(color2, color1, mixAmt * 0.01);
	} else if (mode == 11) {
		// b -> a saturation
		float c = rgb2hsv(color1).g;
		color1 = mix(color1, color2, c * cut);
		color = mix(color2, color1, mixAmt * 0.01);
	} else if (mode == 12) {
		// b -> a value
		float c = rgb2hsv(color1).b;
		color1 = mix(color1, color2, c * cut);
		color = mix(color2, color1, mixAmt * 0.01);
	} else if (mode == 13) {
		// mix
		color2 = mix(color1, color2, cut);
		color = mix(color1, color2, mixAmt * 0.01);
	} else if (mode == 14) {
		// psychedelic
		vec3 c = step(vec3(cut), mix(color1, color2, 0.5));
		color2 = mix(color1, color2, c);
		color = mix(color1, color2, mixAmt * 0.01);
	} else {
		// psychedelic 2 (blendMode == 15)
		vec3 c1 = smoothstep(color1, vec3(cut), color2);
		vec3 c2 = smoothstep(color2, vec3(cut), color1);
		color = mix(c1.brg, c2.gbr, mixAmt * 0.01);
	}

	return color;
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 st = gl_FragCoord.xy / dims;

	vec4 color1 = texture(inputTex, st);
	vec4 color2 = texture(tex, st);

	vec4 color = vec4(0.0, 0.0, 1.0, 1.0);
	color = vec4(blend_colors(color1.rgb, color2.rgb), mix(color1.a, color2.a, mixAmt * 0.01));

	frag = color;
}

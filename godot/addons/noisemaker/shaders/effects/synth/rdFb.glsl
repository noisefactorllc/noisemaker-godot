#version 450
// synth/reactionDiffusion — program "rdFb" (the simulate / feedback pass). Ported from
// wgsl/rdFb.wgsl. Gray-Scott solver: a fixed 9-tap Laplacian (NEAREST integer-neighbour
// samples) drives the A/B integration step (step size s = speed*0.01, applied every
// iteration — there is no deltaTime gate, so the pattern genuinely evolves). Seeds the
// grid (Dave-Hoskins hash — no transcendentals, portable) when the state buffer is empty
// (all four channels zero) or resetState. The simulate pass repeats `iterations` times
// per frame (backend §10.6 iteration ping-pong).
//
// Layout effect: vec4 data[4] (effects/synth/reactionDiffusion.json, uniformLayouts.rdFb).
// Inputs (pass.inputs order): bufTex = binding 1 (the read state buffer), inputTex =
// binding 2 (optional source for f/k/r modulation; bound to a black texture when "none").
// gl_FragCoord is top-left/+0.5 like the WGSL @position — NO Y-flip.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[4]; };
layout(set = 0, binding = 1) uniform sampler2D bufTex;
layout(set = 0, binding = 2) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// 9-tap Laplacian (fixed 1px neighbourhood; reference GLSL weights). NEAREST + texel-
// offset coords fetch exact neighbour texels (no interpolation).
vec3 lp(sampler2D tex, vec2 uv, vec2 size) {
	float pixelStep = 1.0;
	vec3 val = vec3(0.0);
	val = val + texture(tex, (uv + vec2(-pixelStep, -pixelStep)) / size).rgb * 0.05;
	val = val + texture(tex, (uv + vec2(0.0, -pixelStep)) / size).rgb * 0.2;
	val = val + texture(tex, (uv + vec2(pixelStep, -pixelStep)) / size).rgb * 0.05;
	val = val + texture(tex, (uv + vec2(-pixelStep, 0.0)) / size).rgb * 0.2;
	val = val + texture(tex, (uv + vec2(0.0, 0.0)) / size).rgb * -1.0;
	val = val + texture(tex, (uv + vec2(pixelStep, 0.0)) / size).rgb * 0.2;
	val = val + texture(tex, (uv + vec2(-pixelStep, pixelStep)) / size).rgb * 0.05;
	val = val + texture(tex, (uv + vec2(0.0, pixelStep)) / size).rgb * 0.2;
	val = val + texture(tex, (uv + vec2(pixelStep, pixelStep)) / size).rgb * 0.05;
	return val;
}

float map(float value, float inMin, float inMax, float outMin, float outMax) {
	return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float lum(vec3 color) {
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

float hash(vec2 p) {
	vec2 p2 = fract(p * vec2(0.1031, 0.1030));
	p2 = p2 + dot(p2, p2.yx + 33.33);
	return fract((p2.x + p2.y) * p2.x);
}

void main() {
	vec2 resolution = data[0].xy;
	float time = data[0].z; // unused
	float zoom = data[0].w;
	float seed = data[3].w;

	vec2 texSize = vec2(textureSize(bufTex, 0));
	vec4 tex = texture(bufTex, gl_FragCoord.xy / texSize);
	float a = tex.r;
	float b = tex.g;

	// First-frame init / reset detection (all four channels zero).
	bool bufferIsEmpty = (tex.r == 0.0 && tex.g == 0.0 && tex.b == 0.0 && tex.a == 0.0);
	bool resetState = data[3].z > 0.5;

	if (bufferIsEmpty || resetState) {
		// A=1 everywhere, B=1 at sparse random sites.
		a = 1.0;
		b = 0.0;
		if (hash(gl_FragCoord.xy + vec2(seed, seed)) > 0.99) {
			b = 1.0;
		}
		frag = vec4(a, b, 0.0, 1.0);
		return;
	}

	vec3 color = lp(bufTex, gl_FragCoord.xy, texSize);

	vec2 prevFrameCoord = gl_FragCoord.xy / texSize;
	vec3 prevFrame = texture(inputTex, prevFrameCoord).rgb;
	float prevLum = lum(prevFrame);

	float f = data[1].x * 0.001;
	float k = data[1].y * 0.001;
	float r1 = data[1].z * 0.01;
	float r2 = data[1].w * 0.01;
	float s = data[2].x * 0.01;
	float weight = data[2].y * 0.01;
	int sourceF = int(data[2].z);
	int sourceK = int(data[2].w);
	int sourceR1 = int(data[3].x);
	int sourceR2 = int(data[3].y);

	if (sourceF > 0) {
		float val = prevLum;
		if (sourceF == 2) { val = 1.0 - prevLum; }
		else if (sourceF == 3) { val = prevFrame.r; }
		else if (sourceF == 4) { val = prevFrame.g; }
		else if (sourceF == 5) { val = prevFrame.b; }
		else if (sourceF == 6) {
			val = map(prevLum, 0.0, 1.0, 0.01, 0.11);
			f = mix(f, val, weight);
		}
		if (sourceF != 6) {
			val = map(val, 0.0, 1.0, 0.01, 0.11);
			f = val;
		}
	}

	if (sourceK > 0) {
		float val = prevLum;
		if (sourceK == 2) { val = 1.0 - prevLum; }
		else if (sourceK == 3) { val = prevFrame.r; }
		else if (sourceK == 4) { val = prevFrame.g; }
		else if (sourceK == 5) { val = prevFrame.b; }
		else if (sourceK == 6) {
			val = map(prevLum, 0.0, 1.0, 0.045, 0.07);
			k = mix(k, val, weight);
		}
		if (sourceK != 6) {
			val = map(val, 0.0, 1.0, 0.045, 0.07);
			k = val;
		}
	}

	if (sourceR1 > 0) {
		float val = prevLum;
		if (sourceR1 == 2) { val = 1.0 - prevLum; }
		else if (sourceR1 == 3) { val = prevFrame.r; }
		else if (sourceR1 == 4) { val = prevFrame.g; }
		else if (sourceR1 == 5) { val = prevFrame.b; }
		else if (sourceR1 == 6) {
			val = map(prevLum, 0.0, 1.0, 0.5, 1.2);
			r1 = mix(r1, val, weight);
		}
		if (sourceR1 != 6) {
			val = map(val, 0.0, 1.0, 0.5, 1.2);
			r1 = val;
		}
	}

	if (sourceR2 > 0) {
		float val = prevLum;
		if (sourceR2 == 2) { val = 1.0 - prevLum; }
		else if (sourceR2 == 3) { val = prevFrame.r; }
		else if (sourceR2 == 4) { val = prevFrame.g; }
		else if (sourceR2 == 5) { val = prevFrame.b; }
		else if (sourceR2 == 6) {
			val = map(prevLum, 0.0, 1.0, 0.2, 0.5);
			r2 = mix(r2, val, weight);
		}
		if (sourceR2 != 6) {
			val = map(val, 0.0, 1.0, 0.2, 0.5);
			r2 = val;
		}
	}

	float a2 = clamp(a + (r1 * color.r - a * b * b + f * (1.0 - a)) * s, 0.0, 1.0);
	float b2 = clamp(b + (r2 * color.g + a * b * b - (k + f) * b) * s, 0.0, 1.0);

	frag = vec4(a2, b2, 0.0, 1.0);
}

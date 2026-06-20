#version 450
// synth/modPattern — ported from wgsl/modPattern.wgsl (top-left origin = Godot/Vulkan,
// no Y-flip). Interference patterns from modulo operations. Single pass, no inputs.
// Helpers (glsl_mod/glsl_mod2, shape, smoothFract/2/3) inlined verbatim. Uses no
// nm_core primitives. Packed uniformLayout: vec4 data[5] (effects/synth/modPattern.json).
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[5]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// GLSL-compatible mod: mod(x, y) = x - y * floor(x/y). WGSL % behaves like C fmod,
// which differs for negatives.
float glsl_mod(float x, float y) {
	return x - y * floor(x / y);
}

vec2 glsl_mod2(vec2 x, vec2 y) {
	return x - y * floor(x / y);
}

// Generate a geometric shape from the given coordinates.
float shape(int shapeIndex, vec2 p) {
	float v;
	if (shapeIndex < 1) {
		// plus
		v = max(p.x, p.y);
	} else if (shapeIndex < 2) {
		// square
		v = min(p.x, p.y);
	} else {
		// diamond
		v = abs(p.x - p.y);
	}
	return v;
}

float smoothFract(float x) {
	int smoothing = int(data[3].w);
	float f = fract(x);
	float edgeWidth = float(smoothing) * 0.01;
	if (f > 1.0 - edgeWidth) {
		return smoothstep(0.0, edgeWidth, 1.0 - f);
	}
	return f;
}

vec2 smoothFract2(vec2 v) {
	return vec2(smoothFract(v.x), smoothFract(v.y));
}

vec3 smoothFract3(vec3 v) {
	return vec3(smoothFract(v.x), smoothFract(v.y), smoothFract(v.z));
}

void main() {
	// Unpack uniforms
	vec2 resolution = data[0].xy;
	float time = data[0].z;

	int shape1 = int(data[1].x);
	float scale1 = data[1].y;
	float repeat1 = data[1].z;
	int shape2 = int(data[1].w);

	float scale2 = data[2].x;
	float repeat2 = data[2].y;
	int shape3 = int(data[2].z);
	float scale3 = data[2].w;

	float repeat3 = data[3].x;
	int blend = int(data[3].y);
	int speed = int(data[3].z);
	int smoothing = int(data[3].w);
	int animMode = int(data[4].x);

	vec2 res = resolution;
	if (res.x < 1.0) { res = vec2(1024.0, 1024.0); }

	// Normalized coordinates
	vec2 uv = (gl_FragCoord.xy - res * 0.5) / min(res.x, res.y);

	float spd = floor(float(speed));
	float anim = time * spd;
	float TAU = 6.28318530718;

	// Create repeating cells with hard edges
	// mod(uv * scale, 2.0) creates repeating cells from 0 to 2
	// Subtracting 1.0 centers them from -1 to 1
	// abs() folds them, so you get a pattern that goes 0->1->0->1 with sharp peaks
	float s1 = 20.1 - scale1; // Map scale so larger number = lower frequency
	vec2 p = abs(glsl_mod2(uv * s1, vec2(2.0)) - vec2(1.0));

	// Pan mode: per-layer directional oscillation, scaled to layer frequency
	if (animMode == 1) {
		float osc1 = sin(time * TAU * spd) * 0.03;
		p += vec2(osc1, 0.0);
	}

	// Generate a shape/pattern for the repeated coordinates
	float n1 = shape(shape1, p);

	// Phase mode: offset each layer independently
	float phase1 = (animMode == 2) ? anim : 0.0;
	float phase2 = (animMode == 2) ? anim : 0.0;
	float phase3 = (animMode == 2) ? anim : 0.0;

	// Repeat the same fold operation but at a different frequency, and generate another shape
	float s2 = 10.1 - scale2; // Map scale so larger number = lower frequency
	p = abs(glsl_mod2(p * s2, vec2(2.0)) - vec2(1.0));

	// Pan mode: layer 2 pans up
	if (animMode == 1) {
		float osc2 = sin(time * TAU * spd) * 0.07;
		p += vec2(0.0, osc2);
	}

	float n2 = shape(shape2, p);

	// Multiply each pattern by different amounts (like 3 and 5) and add them together.
	// The fract() wraps values back to 0-1, creating interference patterns
	float val = 0.0;
	if (blend < 1) {
		val = fract(n1 * repeat1 + phase1 + n2 * repeat2 + phase2);
	} else {
		val = smoothFract(n1 * repeat1 + phase1 + n2 * repeat2 + phase2);
	}

	// Repeat again with scale3 frequency, modifying the coordinates and creating another
	// shape/pattern
	float s3 = 6.1 - scale3; // Map scale so larger number = lower frequency
	p = abs(glsl_mod2(p * s3, vec2(2.0)) - vec2(1.0));

	// Pan mode: layer 3 pans left
	if (animMode == 1) {
		float osc3 = sin(time * TAU * spd) * 0.15;
		p += vec2(-osc3, 0.0);
	}

	float n3 = shape(shape3, p);

	// Shift mode: add time offset at the final blend stage
	float shift = (animMode == 0) ? anim : 0.0;

	// Combine layers with selected blend mode
	vec3 color;
	if (blend < 1) {
		// add
		color = smoothFract3(vec3(fract(val + n3 * repeat3 + phase3 + shift)));
	} else if (blend < 2) {
		// max
		color = vec3(max(val, smoothFract(n3 * repeat3 + phase3 + shift)));
	} else if (blend < 3) {
		// mix
		color = vec3(mix(val, smoothFract(n3 * repeat3 + phase3 + shift), 0.5));
	} else {
		// rgb
		color = smoothFract3(vec3(n1 * repeat1 + phase1, n2 * repeat2 + phase2, n3 * repeat3 + phase3 + shift));
	}

	frag = vec4(color, 1.0);
}

#version 450
// mixer/patternMix — ported PIXEL-IDENTICALLY from wgsl/patternMix.wgsl. Mixes two
// inputs (colorA = inputTex, colorB = tex) using a geometric pattern mask selected
// by patternType. No-layout effect: backend injects the Params UBO + `#define`s for
// patternType/scale/thickness/smoothness/rotation/invert. Two inputs (pass.inputs
// order): inputTex = base (binding 1), tex = pattern source (binding 2).
//
// Notes:
//  * All pattern helpers are THIS effect's own copies, inlined verbatim.
//  * WGSL `%` on floats (checkerboard `(cell.x+cell.y) % 2.0`, hexagons `(p % s)`)
//    matches the reference GLSL golden's floor-based `mod()` (the golden uses
//    `mod(...)` here, and `p` is centered/scaled so the choice is observable).
//  * WGSL `atan2(y, x)` → GLSL `atan(y, x)` (same arg order).
//  * `position.xy` → `gl_FragCoord.xy`, no Y-flip.
//  * patternType/invert are int uniforms; the injected defines expand to floats, so
//    they are cast with `int(...)` at the comparison sites.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;
const float SQRT3 = 1.7320508075688772;

const int CHECKERBOARD = 0;
const int CONCENTRIC_RINGS = 1;
const int DOTS = 2;
const int GRID = 3;
const int HEXAGONS = 4;
const int RADIAL_LINES = 5;
const int SPIRAL_PATTERN = 6;
const int STRIPES = 7;
const int TRIANGULAR_GRID = 8;
const float TAU = 6.28318530718;

vec2 rotate2D(vec2 p, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

float stripes(vec2 p, float t, float sm) {
	float stripe = fract(p.x);
	float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, stripe);
	float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, stripe);
	return edge1 - edge2;
}

float checkerboard(vec2 p, float sm) {
	vec2 f = fract(p);
	float d = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	vec2 cell = floor(p);
	float check = mod(cell.x + cell.y, 2.0);
	float edge = smoothstep(0.0, sm * 0.5, d);
	return mix(1.0 - check, check, edge);
}

float grid(vec2 p, float t, float sm) {
	vec2 f = fract(p);
	float lineX = smoothstep(t * 0.5 - sm, t * 0.5 + sm, abs(f.x - 0.5));
	float lineY = smoothstep(t * 0.5 - sm, t * 0.5 + sm, abs(f.y - 0.5));
	return 1.0 - min(lineX, lineY);
}

float dots(vec2 p, float t, float sm) {
	vec2 f = fract(p) - vec2(0.5, 0.5);
	float d = length(f);
	float r = t * 0.5;
	return 1.0 - smoothstep(r - sm, r + sm, d);
}

float hexDist(vec2 p) {
	vec2 ap = abs(p);
	return max(ap.x * 0.5 + ap.y * (SQRT3 / 2.0), ap.x);
}

float hexagons(vec2 p, float t, float sm) {
	vec2 s = vec2(1.0, SQRT3);
	vec2 h = s * 0.5;
	vec2 a = mod(p, s) - h;
	vec2 b = mod(p + h, s) - h;
	vec2 g;
	if (length(a) < length(b)) {
		g = a;
	} else {
		g = b;
	}
	float d = hexDist(g);
	float edge = 0.5 * t;
	return smoothstep(edge + sm, edge - sm, d);
}

// Concentric rings pattern
float concentricRings(vec2 p, float t, float sm) {
	float d = fract(length(p));
	float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, d);
	float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, d);
	return edge1 - edge2;
}

// Radial lines pattern
float radialLines(vec2 p, float t, float sm) {
	float lineCount = max(1.0, floor(20.0 * t));
	float angle = atan(p.y, p.x);
	float d = fract(angle / TAU * lineCount);
	float edge1 = smoothstep(0.5 - 0.25 - sm, 0.5 - 0.25 + sm, d);
	float edge2 = smoothstep(0.5 + 0.25 - sm, 0.5 + 0.25 + sm, d);
	return edge1 - edge2;
}

// Triangular grid pattern
float triangularGrid(vec2 p, float t, float sm) {
	vec2 skewed = vec2(p.x - p.y / SQRT3, p.y * 2.0 / SQRT3);
	vec2 cell = floor(skewed);
	vec2 f = fract(skewed);

	float d;
	if (f.x + f.y < 1.0) {
		d = min(min(f.x, f.y), 1.0 - f.x - f.y);
	} else {
		d = min(min(1.0 - f.x, 1.0 - f.y), f.x + f.y - 1.0);
	}

	float edge = (1.0 - t) * 0.4;
	return smoothstep(edge - sm, edge + sm, d);
}

// Spiral pattern
float spiralPattern(vec2 p, float t, float sm) {
	float dist = length(p);
	float angle = atan(p.y, p.x);
	float d = fract(angle / TAU + dist);
	float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, d);
	float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, d);
	return edge1 - edge2;
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 st = gl_FragCoord.xy / dims;

	vec4 colorA = texture(inputTex, st);
	vec4 colorB = texture(tex, st);

	// Center and aspect-correct
	float aspect = dims.x / dims.y;
	vec2 p = (st - vec2(0.5, 0.5)) * 2.0;
	p.x = p.x * aspect;

	// Apply rotation
	float rad = rotation * PI / 180.0;
	p = rotate2D(p, rad);

	// Apply scale (lower scale = higher frequency, matching synth/pattern)
	p = p * (21.0 - scale);

	// Compute pattern mask
	float m = 0.0;
	int pt = int(patternType);
	if (pt == CHECKERBOARD) {
		m = checkerboard(p, smoothness);
	} else if (pt == CONCENTRIC_RINGS) {
		m = concentricRings(p, thickness, smoothness);
	} else if (pt == DOTS) {
		m = dots(p, thickness, smoothness);
	} else if (pt == GRID) {
		m = grid(p, thickness, smoothness);
	} else if (pt == HEXAGONS) {
		m = hexagons(p, thickness, smoothness);
	} else if (pt == RADIAL_LINES) {
		m = radialLines(p, thickness, smoothness);
	} else if (pt == SPIRAL_PATTERN) {
		m = spiralPattern(p, thickness, smoothness);
	} else if (pt == STRIPES) {
		m = stripes(p, thickness, smoothness);
	} else if (pt == TRIANGULAR_GRID) {
		m = triangularGrid(p, thickness, smoothness);
	}

	// Invert swaps which input shows in the pattern
	if (int(invert) == 1) {
		m = 1.0 - m;
	}

	// Mix: m=0 shows A, m=1 shows B
	vec4 color = mix(colorA, colorB, m);
	color.a = max(colorA.a, colorB.a);

	frag = color;
}

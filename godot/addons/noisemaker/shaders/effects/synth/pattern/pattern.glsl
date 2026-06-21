#version 450
// synth/pattern — ported PIXEL-IDENTICALLY from wgsl/pattern.wgsl. Geometric
// pattern generator: checkerboard, concentricRings, dots, grid, hexagons,
// radialLines, spiral, stripes, triangularGrid, hearts, waves, zigzag.
//
// No-layout effect (like solid.glsl / osc2d.glsl): the backend SYNTHESIZES the
// Params UBO and injects, after #version, `#define <name> data[slot].comp` for
// every engine global (resolution/time/aspectRatio/tileOffset/fullResolution/
// renderScale) AND every param uniform (patternType/scale/thickness/smoothness/
// rotation/skew/animation/speed/fgColor/bgColor). So we use the bare reference
// names directly and declare NO UBO and NO uniforms. This is a generator with no
// input samplers.
//
// pattern uses NONE of the shared nm_core primitives: rotate2D is its OWN variant
// (inlined verbatim per PORTING-GUIDE rule 2), float `%` maps to the GLSL built-in
// `mod` (a - b*floor(a/b), == WGSL %), and PI/TAU/SQRT3 are the effect's own
// truncated literals inlined under renamed symbols. So nm_core is NOT included.
//
// Coordinate note (PORTING-GUIDE golden rule 1 / coordinate parity): the WGSL has
// NO explicit Y-flip — it normalizes `position.xy / u.resolution` straight — and
// uses u.resolution (the render-target size), NOT fullResolution. gl_FragCoord
// here is top-left (matches WGSL); the backend applies a single global flip at
// present, so we divide straight (gl_FragCoord.xy / resolution) with NO per-effect
// flip, matching the bottom-left HLSL disambiguator (Pattern.hlsl).
//
// NUMERIC HAZARDS handled:
//  * GLSL `mod` for float `%` (checkerboard parity; hexagons a/b = p % s per axis).
//  * atan(y, x) arg order copied literally from WGSL atan2(p.y, p.x).
//  * WGSL select(falseVal, trueVal, cond) -> GLSL ternary cond ? trueVal : falseVal
//    (pan panPeriod).
//  * floor(speed) — speed is int; cast to float before floor.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Local constants exactly as the WGSL declares them (truncated literals).
const float PAT_PI    = 3.14159265359;
const float PAT_SQRT3 = 1.7320508075688772;
const float PAT_TAU   = 6.28318530718;

// Pattern type constants (mirror WGSL).
const int CHECKERBOARD    = 0;
const int CONCENTRIC_RINGS = 1;
const int DOTS            = 2;
const int GRID            = 3;
const int HEXAGONS        = 4;
const int RADIAL_LINES    = 5;
const int SPIRAL_PATTERN  = 6;
const int STRIPES         = 7;
const int TRIANGULAR_GRID = 8;
const int HEARTS          = 9;
const int WAVES           = 10;
const int ZIGZAG          = 11;

// Rotate a 2D point (verbatim from WGSL).
vec2 rotate2D(vec2 p, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// Stripes pattern.
float stripes(vec2 p, float t, float sm) {
	float stripe = fract(p.x);
	// Apply smoothness to both edges of the stripe
	float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, stripe);
	float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, stripe);
	return edge1 - edge2;
}

// Checkerboard pattern.
float checkerboard(vec2 p, float sm) {
	vec2 f = fract(p);
	// Distance to nearest cell edge
	float d = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	// Determine which cell we're in
	vec2 cell = floor(p);
	// WGSL: (cell.x + cell.y) % 2.0 — GLSL mod == a - b*floor(a/b)
	float check = mod(cell.x + cell.y, 2.0);
	// Apply smoothness at edges
	float edge = smoothstep(0.0, sm * 0.5, d);
	return mix(1.0 - check, check, edge);
}

// Grid pattern (lines forming a grid).
float grid(vec2 p, float t, float sm) {
	vec2 f = fract(p);
	float lineX = smoothstep(t * 0.5 - sm, t * 0.5 + sm, abs(f.x - 0.5));
	float lineY = smoothstep(t * 0.5 - sm, t * 0.5 + sm, abs(f.y - 0.5));
	return 1.0 - min(lineX, lineY);
}

// Dots pattern (circles on a grid).
float dots(vec2 p, float t, float sm) {
	vec2 f = fract(p) - vec2(0.5, 0.5);
	float d = length(f);
	float radius = t * 0.5;
	return 1.0 - smoothstep(radius - sm, radius + sm, d);
}

// Hexagon distance function.
float hexDist(vec2 p) {
	vec2 ap = abs(p);
	return max(ap.x * 0.5 + ap.y * (PAT_SQRT3 / 2.0), ap.x);
}

// Hexagons pattern.
float hexagons(vec2 p, float t, float sm) {
	// Scale for hexagonal grid
	vec2 s = vec2(1.0, PAT_SQRT3);
	vec2 h = s * 0.5;

	// Two offset grids. WGSL: (p % s) - h and ((p + h) % s) - h — GLSL mod per axis.
	vec2 a = mod(p, s) - h;
	vec2 b = mod(p + h, s) - h;

	// Choose closest hexagon center
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

// Concentric rings pattern (timeOffset expands/contracts from center).
float concentricRings(vec2 p, float t, float sm, float timeOffset) {
	float d = fract(length(p) + timeOffset);
	float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, d);
	float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, d);
	return edge1 - edge2;
}

// Radial lines pattern (timeOffset rotates around center).
float radialLines(vec2 p, float t, float sm, float timeOffset) {
	float lineCount = floor(scale);
	float angle = atan(p.y, p.x) + timeOffset * PAT_TAU;
	float d = fract(angle / PAT_TAU * lineCount);
	float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, d);
	float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, d);
	return edge1 - edge2;
}

// Triangular grid pattern.
float triangularGrid(vec2 p, float t, float sm) {
	vec2 skewed = vec2(p.x - p.y / PAT_SQRT3, p.y * 2.0 / PAT_SQRT3);
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

// Spiral pattern (timeOffset rotates arms).
float spiralPattern(vec2 p, float t, float sm, float timeOffset) {
	float dist = length(p);
	float angle = atan(p.y, p.x) + timeOffset * PAT_TAU;
	float d = fract(angle / PAT_TAU + dist);
	float edge1 = smoothstep(0.5 - t * 0.5 - sm, 0.5 - t * 0.5 + sm, d);
	float edge2 = smoothstep(0.5 + t * 0.5 - sm, 0.5 + t * 0.5 + sm, d);
	return edge1 - edge2;
}

// Heart SDF (based on Inigo Quilez).
float heartSDF(vec2 p_in) {
	vec2 p = vec2(abs(p_in.x), p_in.y);
	if (p.y + p.x > 1.0) {
		vec2 d = p - vec2(0.25, 0.75);
		return sqrt(dot(d, d)) - sqrt(2.0) / 4.0;
	}
	vec2 d1 = p - vec2(0.0, 1.0);
	float proj = 0.5 * max(p.x + p.y, 0.0);
	vec2 d2 = p - proj;
	return sqrt(min(dot(d1, d1), dot(d2, d2))) * sign(p.x - p.y);
}

// Hearts pattern (tiled heart shapes).
float hearts(vec2 p, float t, float sm) {
	vec2 cell = fract(p) - 0.5;
	cell.y += 0.25;
	float d = heartSDF(cell * 2.4);
	float radius = 0.15 - (t * 0.15);
	float s = min(sm, radius + 0.15);
	return 1.0 - smoothstep(-radius - s, -radius + s, d);
}

// Waves pattern (sine-displaced horizontal lines).
float waves(vec2 p, float t, float sm) {
	float y = fract(p.y) - 0.5;
	y -= cos(p.x * PAT_TAU) * 0.15;
	float dist = abs(y);
	float halfW = t * 0.2;
	float s = min(sm, halfW + 0.01);
	return 1.0 - smoothstep(halfW - s, halfW + s, dist);
}

// Zigzag pattern (V-shaped line per cell).
float zigzag(vec2 p, float t, float sm) {
	vec2 f = fract(p);
	// Zigzag line: y = 1 - 2*abs(x - 0.5), scaled to 0.25–0.75 range
	float lineY = 1.0 - 2.0 * abs(f.x - 0.5);
	float dist = abs(f.y - lineY * 0.5 - 0.25);
	// Max vertical distance to cell edge is 0.25; cap halfW + sm to stay within
	float halfW = t * 0.12;
	float s = min(sm, max(0.24 - halfW, 0.005));
	return 1.0 - smoothstep(halfW - s, halfW + s, dist);
}

void main() {
	// Normalize coordinates. Top-left port: divide straight by resolution (the
	// render-target size, matching the WGSL u.resolution), NO per-effect Y-flip.
	vec2 st = gl_FragCoord.xy / resolution;
	st = (st - vec2(0.5, 0.5)) * 2.0;
	st.x = st.x * aspectRatio;

	// Apply rotation
	float rad = rotation * PAT_PI / 180.0;
	st = rotate2D(st, rad);

	// Apply animation rotation/pan (only for non-centered patterns)
	bool centered = patternType == CONCENTRIC_RINGS || patternType == RADIAL_LINES || patternType == SPIRAL_PATTERN;
	if (!centered && animation == 2) {
		st = rotate2D(st, time * PAT_TAU * floor(float(speed)));
	}

	// Horizontal shear (screen-vertical axis), applied as the final transform
	st.x = st.x + st.y * skew;

	// Apply scale, mapping so lower scale = higher frequency
	vec2 p = st * (21.0 - scale);

	if (!centered && animation == 1) {
		// Checkerboard's spatial period along p.x is 2 (cell parity flips every unit),
		// so double the shift to keep the time=1 wrap landing on an even cell boundary.
		// WGSL select(1.0, 2.0, cond) -> GLSL cond ? 2.0 : 1.0.
		float panPeriod = (patternType == CHECKERBOARD) ? 2.0 : 1.0;
		p.x += time * -floor(float(speed)) * panPeriod;
	}

	// Compute pattern value
	float m = 0.0;

	if (patternType == CHECKERBOARD) {
		m = checkerboard(p, smoothness);
	} else if (patternType == CONCENTRIC_RINGS) {
		m = concentricRings(p, thickness, smoothness, -time * floor(float(speed)));
	} else if (patternType == DOTS) {
		m = dots(p, thickness, smoothness);
	} else if (patternType == GRID) {
		m = grid(p, thickness, smoothness);
	} else if (patternType == HEXAGONS) {
		m = hexagons(p, thickness, smoothness);
	} else if (patternType == RADIAL_LINES) {
		m = radialLines(p, thickness, smoothness, time * floor(float(speed)));
	} else if (patternType == SPIRAL_PATTERN) {
		m = spiralPattern(p, thickness, smoothness, -time * floor(float(speed)));
	} else if (patternType == STRIPES) {
		m = stripes(p, thickness, smoothness);
	} else if (patternType == TRIANGULAR_GRID) {
		m = triangularGrid(p, thickness, smoothness);
	} else if (patternType == HEARTS) {
		m = hearts(p, thickness, smoothness);
	} else if (patternType == WAVES) {
		m = waves(p, thickness, smoothness);
	} else if (patternType == ZIGZAG) {
		m = zigzag(p, thickness, smoothness);
	}

	// Mix colors
	vec3 color = mix(bgColor, fgColor, m);

	frag = vec4(color, 1.0);
}

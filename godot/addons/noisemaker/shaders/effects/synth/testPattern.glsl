#version 450
// synth/testPattern — ported PIXEL-IDENTICALLY from the canonical WGSL source
//   shaders/effects/synth/testPattern/wgsl/testPattern.wgsl
// Cross-checked against the Unity HLSL port (Shaders/Effects/synth/TestPattern.hlsl).
//
// Test patterns for debugging and calibration. A single render pass selects one of
// seven patterns (checkerboard, colorBars, gradient, uvMap, gridLines, colorGrid,
// dotGrid) by the `pattern` int uniform; `gridSize` controls cell density.
//
// No-layout effect (like solid.glsl / osc2d.glsl): the backend SYNTHESIZES the
// Params UBO and injects, after #version, `#define <name> data[slot].comp` for every
// engine global (resolution/time/aspectRatio/tileOffset/fullResolution/renderScale)
// AND every param uniform (pattern/gridSize). We use the bare names directly and
// declare NO UBO and NO uniforms. The injected param names resolve to FLOAT vec
// components, so the i32 params are read via int(pattern)/int(gridSize) — the packed
// values are integral, so the truncating cast is exact.
//
// This effect uses NO shared primitives (no pcg/prng/random/map/periodicFunction/
// positiveModulo/PI/TAU), so nm_core.glsl is intentionally not included.
//
// Coordinate note (PORTING-GUIDE golden rule 1): the WGSL main() divides
// position.xy straight (NO explicit Y-flip), so there is nothing to drop — we use
// gl_FragCoord (top-left, +0.5) directly. NOTE this effect divides the global pixel
// coord by the FULL vec2 `fr` (both axes), NOT by .y only (test patterns live in
// 0..1 screen-UV space). Mirrors WGSL main() exactly.
//
// HAZARDS handled (all verbatim, no arithmetic reassociation):
//  * select(a,b,cond) -> cond ? b : a (WGSL arg order preserved).
//  * i32(float) -> int(float): truncation toward zero. uv >= 0 so cellX/cellY/
//    temp%10 stay non-negative; bare `%` is kept (NOT positiveModulo).
//  * GLYPH bit test: (GLYPH[digit] >> uint(bitIndex)) & 1, bitIndex in [0,14] >= 0.
//  * gridLines: fwidthFine(uv*n) on the non-tile path -> GLSL dFdxFine/dFdyFine,
//    fwidth-magnitude = abs(dFdxFine) + abs(dFdyFine). Computed UNCONDITIONALLY in
//    uniform control flow (as the WGSL does), overridden only when tiling.
//  * golden-ratio hue constant kept full-precision: 0.618033988749895.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// 3x5 pixel font for digits 0-9. Each digit is encoded as 15 bits
// (3 columns x 5 rows, row-major). Verbatim from WGSL `GLYPH`.
const int TP_GLYPH[10] = int[10](
	0x7B6F,  // 0: 111 101 101 101 111
	0x2492,  // 1: 010 010 010 010 010
	0x73E7,  // 2: 111 001 111 100 111
	0x72CF,  // 3: 111 001 011 001 111
	0x5BC9,  // 4: 101 101 111 001 001
	0x79CF,  // 5: 111 100 111 001 111
	0x79EF,  // 6: 111 100 111 101 111
	0x7249,  // 7: 111 001 001 001 001
	0x7BEF,  // 8: 111 101 111 101 111
	0x7BCF   // 9: 111 101 111 001 111
);

// Sample a glyph at local coordinates (0-2, 0-4). Verbatim from WGSL.
bool tp_sampleGlyph(int digit, int x, int y) {
	if (digit < 0 || digit > 9 || x < 0 || x > 2 || y < 0 || y > 4) {
		return false;
	}
	int bitIndex = y * 3 + (2 - x);  // row-major, top-left origin
	return ((TP_GLYPH[digit] >> uint(bitIndex)) & 1) == 1;
}

// Render a number at a position within a cell. Verbatim from WGSL.
bool tp_renderNumber(int number, vec2 cellUV) {
	// Determine how many digits we need
	int numDigits = 1;
	if (number >= 10) { numDigits = 2; }
	if (number >= 100) { numDigits = 3; }

	// Glyph dimensions in UV space (centered, scaled to fit nicely)
	float glyphWidth = 0.15;
	float glyphHeight = 0.35;
	float spacing = 0.05;

	float totalWidth = float(numDigits) * glyphWidth + float(numDigits - 1) * spacing;
	float startX = 0.5 - totalWidth * 0.5;
	float startY = 0.5 - glyphHeight * 0.5;

	// Check if we're in the vertical range for glyphs
	if (cellUV.y < startY || cellUV.y >= startY + glyphHeight) {
		return false;
	}

	// Extract digits (right to left)
	int digits[3] = int[3](0, 0, 0);
	int temp = number;
	for (int i = 0; i < 3; i++) {
		digits[i] = temp % 10;
		temp = temp / 10;
	}

	// Check each digit position (left to right)
	for (int d = 0; d < numDigits; d++) {
		float digitX = startX + float(d) * (glyphWidth + spacing);

		if (cellUV.x >= digitX && cellUV.x < digitX + glyphWidth) {
			// We're in this digit's horizontal range
			float localX = (cellUV.x - digitX) / glyphWidth;
			float localY = (cellUV.y - startY) / glyphHeight;

			// Map to 3x5 grid
			int gx = int(localX * 3.0);
			int gy = int(localY * 5.0);

			// Get the correct digit (numDigits-1-d because digits[] is reversed)
			int digit = digits[numDigits - 1 - d];

			return tp_sampleGlyph(digit, gx, gy);
		}
	}

	return false;
}

// Pattern 0: Numbered checkerboard. Verbatim from WGSL.
vec4 tp_checkerboard(vec2 uv) {
	int n = max(int(gridSize), 1);
	int cellX = int(uv.x * float(n)) % n;
	int cellY = int(uv.y * float(n)) % n;

	int cellNum = (n - 1 - cellY) * n + cellX;

	bool isWhiteCell = ((cellX + cellY) % 2) == 0;

	vec2 cellUV = fract(uv * float(n));

	bool isGlyph = tp_renderNumber(cellNum, cellUV);

	// WGSL select(a,b,cond) == cond ? b : a (arg order preserved literally).
	float cellColor = isWhiteCell ? 1.0 : 0.0;    // select(0.0, 1.0, isWhiteCell)
	float glyphColor = isWhiteCell ? 0.0 : 1.0;   // select(1.0, 0.0, isWhiteCell)
	float finalColor = isGlyph ? glyphColor : cellColor; // select(cellColor, glyphColor, isGlyph)

	return vec4(vec3(finalColor), 1.0);
}

// Pattern 1: 8 vertical SMPTE-style color bars. Verbatim from WGSL.
vec4 tp_colorBars(vec2 uv) {
	int bar = int(uv.x * 8.0);
	bar = clamp(bar, 0, 7);

	// white, yellow, cyan, green, magenta, red, blue, black
	vec3 colors[8] = vec3[8](
		vec3(1.0, 1.0, 1.0),
		vec3(1.0, 1.0, 0.0),
		vec3(0.0, 1.0, 1.0),
		vec3(0.0, 1.0, 0.0),
		vec3(1.0, 0.0, 1.0),
		vec3(1.0, 0.0, 0.0),
		vec3(0.0, 0.0, 1.0),
		vec3(0.0, 0.0, 0.0)
	);

	return vec4(colors[bar], 1.0);
}

// Pattern 2: Horizontal black-to-white gradient ramp. Verbatim from WGSL.
vec4 tp_gradientRamp(vec2 uv) {
	return vec4(vec3(uv.x), 1.0);
}

// Pattern 3: UV map (R=u, G=v, B=0). Verbatim from WGSL.
vec4 tp_uvMapPattern(vec2 uv) {
	return vec4(uv.x, uv.y, 0.0, 1.0);
}

// Pattern 4: Thin white grid lines on black. Verbatim from WGSL.
// `fw` is computed unconditionally (fwidthFine must be evaluated in uniform
// control flow), then overridden on the tiling path with an analytic width.
vec4 tp_gridLines(vec2 uv) {
	int n = max(int(gridSize), 1);
	vec2 cellUV = fract(uv * float(n));
	vec2 edge = min(cellUV, 1.0 - cellUV);
	// Non-tiling: original fwidth-based AA (byte-identical baseline).
	// Tiling: analytic AA width mirroring glsl/testPattern.glsl, which is
	// seam-stable across tiles where screen-space derivatives are not.
	bool isTile = length(tileOffset) > 0.0;
	// fwidthFine must be evaluated in uniform control flow (function scope),
	// so compute it unconditionally, then override only when tiling. The
	// analytic-width divide is skipped entirely on the non-tile path.
	// WGSL fwidthFine(p) == abs(dpdxFine(p)) + abs(dpdyFine(p)).
	vec2 p = uv * float(n);
	vec2 fw = abs(dFdxFine(p)) + abs(dFdyFine(p));
	float edgeMul = 1.5;
	if (isTile) {
		// select(resolution, fullResolution, fullResolution.x > 0.0)
		vec2 fr = (fullResolution.x > 0.0) ? fullResolution : resolution;
		fw = vec2(1.0) / fr * float(n);
		edgeMul = 2.0;
	}
	float line = 1.0 - smoothstep(0.0, edgeMul * fw.x, edge.x) * smoothstep(0.0, edgeMul * fw.y, edge.y);
	return vec4(vec3(line), 1.0);
}

// HSV to RGB (hue only, full saturation & value). Verbatim from WGSL.
vec3 tp_hue2rgb(float h) {
	float r = abs(h * 6.0 - 3.0) - 1.0;
	float g = 2.0 - abs(h * 6.0 - 2.0);
	float b = 2.0 - abs(h * 6.0 - 4.0);
	return clamp(vec3(r, g, b), vec3(0.0), vec3(1.0));
}

// Pattern 5: Each cell gets a unique hue. Verbatim from WGSL.
vec4 tp_colorGrid(vec2 uv) {
	int n = max(int(gridSize), 1);
	int cellX = int(uv.x * float(n)) % n;
	int cellY = int(uv.y * float(n)) % n;
	int cellIndex = cellY * n + cellX;
	float hue = fract(float(cellIndex) * 0.618033988749895);
	return vec4(tp_hue2rgb(hue), 1.0);
}

// Pattern 6: Filled circle at each grid intersection. Verbatim from WGSL.
vec4 tp_dotGrid(vec2 uv) {
	int n = max(int(gridSize), 1);
	vec2 scaled = uv * float(n);
	vec2 nearest = round(scaled);
	float dist = length(scaled - nearest);
	float d = 1.0 - smoothstep(0.12, 0.15, dist);
	return vec4(vec3(d), 1.0);
}

void main() {
	// Tile-aware global UV (mirror WGSL main()). Non-tiling
	// (tileOffset=(0,0), fullResolution=resolution) is byte-identical.
	// WGSL: fr = select(resolution, fullResolution, fullResolution.x > 0.0)
	vec2 fr = (fullResolution.x > 0.0) ? fullResolution : resolution;
	vec2 uv = (gl_FragCoord.xy + tileOffset) / fr;  // divides by FULL vec2 (both axes)

	int patternI = int(pattern);
	if (patternI == 1) {
		frag = tp_colorBars(uv);
	} else if (patternI == 2) {
		frag = tp_gradientRamp(uv);
	} else if (patternI == 3) {
		frag = tp_uvMapPattern(uv);
	} else if (patternI == 4) {
		frag = tp_gridLines(uv);
	} else if (patternI == 5) {
		frag = tp_colorGrid(uv);
	} else if (patternI == 6) {
		frag = tp_dotGrid(uv);
	} else {
		frag = tp_checkerboard(uv);
	}
}

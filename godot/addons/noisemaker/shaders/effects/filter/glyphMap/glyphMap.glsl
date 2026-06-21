#version 450
// filter/glyphMap (program "glyphMap") — ported PIXEL-IDENTICALLY from wgsl/glyphMap.wgsl.
// Converts the input to ASCII/glyph art: each cellSize×cellSize cell samples its center
// brightness, picks one of 16 hardcoded 5x7 glyph bitmaps (ordered by density, seed-shuffled),
// and renders that glyph (mono or input-colored). Single render pass.
//
// No-layout effect (glyphMap.json has NO uniformLayout): the backend SYNTHESIZES the Params
// UBO + `#define <name> data[slot].comp` for the params (cellSize, seed, colorMode) and the
// engine globals used here (tileOffset, fullResolution, renderScale). Use bare names. The
// int params arrive as float UBO components → narrow with int() at the use sites (matching the
// WGSL's i32()). The WGSL's `Uniforms` struct is just the reference packing.
//
// WGSL→GLSL: textureDimensions→textureSize; textureSample→texture; `select(a,b,c)`→`c?b:a`
// (operands reversed); `v >> u32(n)`→`v >> uint(n)`; bit `&`/`>>` on ints kept. gl_FragCoord
// is top-left/+0.5 like @position — NO Y-flip. At the parity harness tileOffset=(0,0) so the
// non-tiling path runs (byte-identical to a plain grid); the tiling branch is ported verbatim.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const int GLYPH_COUNT = 16;

// PCG PRNG
uvec3 pcg(uvec3 seedv) {
	uvec3 v = seedv * 1664525u + 1013904223u;
	v.x = v.x + v.y * v.z;
	v.y = v.y + v.z * v.x;
	v.z = v.z + v.x * v.y;
	v = v ^ (v >> uvec3(16u));
	v.x = v.x + v.y * v.z;
	v.y = v.y + v.z * v.x;
	v.z = v.z + v.x * v.y;
	return v;
}

// Hash for glyph variant selection per cell
float hash(vec2 p) {
	uvec3 v = pcg(uvec3(
		uint(p.x >= 0.0 ? p.x * 2.0 : -p.x * 2.0 + 1.0),
		uint(p.y >= 0.0 ? p.y * 2.0 : -p.y * 2.0 + 1.0),
		0u
	));
	return float(v.x) / float(0xffffffffu);
}

// Get one row (5 bits) of a glyph bitmap. g: glyph index (0-15), y: row (0-6).
int glyphRow(int g, int y) {
	if (g == 0) { return 0; }
	if (g == 1) {
		if (y == 5) { return 4; }
		return 0;
	}
	if (g == 2) {
		if (y == 1 || y == 5) { return 4; }
		return 0;
	}
	if (g == 3) {
		if (y == 3) { return 14; }
		return 0;
	}
	if (g == 4) {
		if (y == 1 || y == 2 || y == 4 || y == 5) { return 4; }
		if (y == 3) { return 14; }
		return 0;
	}
	if (g == 5) {
		if (y == 2 || y == 4) { return 14; }
		return 0;
	}
	if (g == 6) {
		if (y == 1 || y == 5) { return 10; }
		if (y == 2 || y == 4) { return 4; }
		if (y == 3) { return 14; }
		return 0;
	}
	if (g == 7) {
		if (y == 2 || y == 5) { return 14; }
		if (y == 3 || y == 4) { return 10; }
		return 0;
	}
	if (g == 8) {
		if (y == 1 || y == 2 || y == 4 || y == 5) { return 10; }
		if (y == 3) { return 4; }
		return 0;
	}
	if (g == 9) {
		if (y == 1 || y == 3 || y == 5) { return 10; }
		if (y == 2 || y == 4) { return 31; }
		return 0;
	}
	if (g == 10) {
		if (y == 0) { return 25; }
		if (y == 1) { return 26; }
		if (y == 2) { return 4; }
		if (y == 3) { return 9; }
		if (y == 4) { return 11; }
		if (y == 5) { return 19; }
		return 0;
	}
	if (g == 11) {
		if (y == 0) { return 4; }
		if (y == 1) { return 10; }
		if (y == 2) { return 17; }
		if (y == 3) { return 31; }
		if (y == 4 || y == 5) { return 17; }
		return 0;
	}
	if (g == 12) {
		if (y == 0 || y == 1) { return 17; }
		if (y == 2 || y == 3) { return 21; }
		if (y == 4) { return 27; }
		if (y == 5) { return 10; }
		return 0;
	}
	if (g == 13) {
		if (y == 0) { return 17; }
		if (y == 1) { return 27; }
		if (y == 2 || y == 3) { return 21; }
		if (y == 4 || y == 5) { return 17; }
		return 0;
	}
	if (g == 14) {
		if (y == 0 || y == 6) { return 14; }
		if (y == 1) { return 17; }
		if (y == 2) { return 23; }
		if (y == 3) { return 21; }
		if (y == 4) { return 22; }
		if (y == 5) { return 16; }
		return 0;
	}
	return 31;
}

// Return 1.0 if pixel (x, y) is set in glyph g, else 0.0
float glyphPixel(int g, int x, int y) {
	int row = glyphRow(g, y);
	int bit = (row >> uint(4 - x)) & 1;
	return float(bit);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 tOffset = tileOffset;
	bool isTile = length(tOffset) > 0.0;
	vec2 pixelCoord = gl_FragCoord.xy;
	int cs = max(int(cellSize), 1);
	if (isTile) {
		pixelCoord = gl_FragCoord.xy + tOffset;
		cs = clamp(int(float(cellSize) * renderScale), 1, 512);
	}
	float csf = float(cs);

	// Which cell are we in?
	vec2 cellIndex = floor(pixelCoord / csf);

	// Local position within the cell, mapped to 5x7 glyph grid
	vec2 localPos = fract(pixelCoord / csf);
	int gx = int(floor(localPos.x * 5.0));
	int gy = int(floor(localPos.y * 7.0));
	gx = clamp(gx, 0, 4);
	gy = clamp(gy, 0, 6);

	// Sample the center of the cell for brightness
	vec2 cellCenter = (cellIndex + 0.5) * csf;
	vec2 sampleUV = cellCenter / texSize;
	if (isTile) {
		sampleUV = clamp((cellCenter - tOffset) / texSize, vec2(0.0), vec2(1.0));
	}
	vec4 srcColor = texture(inputTex, sampleUV);

	// Compute luminance
	float luma = dot(srcColor.rgb, vec3(0.299, 0.587, 0.114));

	// Map luminance to glyph index (0 to GLYPH_COUNT-1)
	int glyphIdx = int(floor(luma * float(GLYPH_COUNT)));
	glyphIdx = clamp(glyphIdx, 0, GLYPH_COUNT - 1);

	// Use seed to rotate/shift glyph selection for variety
	float cellHash = hash(cellIndex + float(seed) * 0.37);
	int variant = int(floor(cellHash * 3.0));

	if (variant == 2 && glyphIdx > 1) {
		glyphIdx = glyphIdx - 1;
	}

	// Get the glyph pixel value
	float glyphVal = glyphPixel(glyphIdx, gx, gy);

	if (int(colorMode) > 0) {
		frag = vec4(srcColor.rgb * glyphVal, 1.0);
	} else {
		frag = vec4(vec3(glyphVal), 1.0);
	}
}

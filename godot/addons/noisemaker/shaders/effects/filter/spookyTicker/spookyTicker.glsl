#version 450
// filter/spookyTicker (program "spookyTicker") — ported PIXEL-IDENTICALLY from
// wgsl/spookyTicker.wgsl. Scrolling bank_ocr digit rows along the BOTTOM of the frame, each
// row scrolling at a seed-derived speed, screen-blended bright with a soft drop shadow. Single
// fragment pass.
//
// No-layout effect (spookyTicker.json has NO uniformLayout): the backend SYNTHESIZES the Params
// UBO + `#define <name> data[slot].comp` for the params (speed, alpha, rows, seed) and the
// engine global `time` (the WGSL binds `time` as a uniform; here it is the injected engine
// global). Use bare names. `rows`/`seed` are int params arriving as float → int() at the use
// sites (matching the WGSL i32()). `time` is the engine global — no local collides with it.
//
// Y-CONVENTION: the WGSL is top-left (@position) and the reference GLSL is GL bottom-left; BOTH
// compute `pyFromBottom = floor((1 - uv.y) * dims.y)` from the bottom, so they agree (unlike
// osd). gl_FragCoord here is TOP-LEFT and our pipeline applies one present-flip (snapshot
// flip_y) that cancels the reference's present-flip, so we port the body VERBATIM on
// gl_FragCoord: uv = gl_FragCoord.xy / dims, pyFromBottom from (1 - uv.y). NO per-effect flip.
// The reference GLSL's renderScale scaling (iScale/ROW_GAP/shadowOff) is a no-op at
// renderScale=1 (the parity harness), so the WGSL's fixed constants are numerically identical.
//
// WGSL→GLSL: textureDimensions→textureSize; textureLoad→texelFetch (integer coord, no sampler);
// `v >> u32(n)`→`v >> uint(n)`; `^`/`*` precedence kept with explicit parens as in the WGSL.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const int GLYPH_W = 7;
const int GLYPH_H = 8;
const int SCALE = 3;
const int CELL_W = 21;  // GLYPH_W * SCALE
const int CELL_H = 24;  // GLYPH_H * SCALE
const int ROW_GAP = 4;

const int GLYPHS[80] = int[80](
	0x3C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C, 0x00,
	0x18, 0x08, 0x08, 0x08, 0x1C, 0x1C, 0x1C, 0x00,
	0x1C, 0x04, 0x04, 0x1C, 0x10, 0x10, 0x1C, 0x00,
	0x1C, 0x04, 0x04, 0x1C, 0x06, 0x06, 0x1E, 0x00,
	0x60, 0x60, 0x60, 0x60, 0x66, 0x7E, 0x06, 0x00,
	0x3C, 0x20, 0x20, 0x3C, 0x04, 0x04, 0x3C, 0x00,
	0x78, 0x48, 0x40, 0x40, 0x7E, 0x42, 0x7E, 0x00,
	0x3C, 0x24, 0x04, 0x0C, 0x08, 0x08, 0x08, 0x00,
	0x3C, 0x24, 0x24, 0x7E, 0x66, 0x66, 0x7E, 0x00,
	0x3E, 0x22, 0x22, 0x3E, 0x06, 0x06, 0x06, 0x00
);

uint hash_mix(uint v) {
	uint r = v;
	r = r ^ (r >> 16u);
	r = r * 0x7feb352du;
	r = r ^ (r >> 15u);
	r = r * 0x846ca68bu;
	r = r ^ (r >> 16u);
	return r;
}

float sample_glyph(int digit, int localX, int localY) {
	int gx = localX / SCALE;
	int gy = localY / SCALE;
	if (gx < 0 || gx >= GLYPH_W || gy < 0 || gy >= GLYPH_H) {
		return 0.0;
	}
	int row = GLYPHS[digit * 8 + gy];
	return float((row >> uint(6 - gx)) & 1);
}

float ticker_row_mask(int pixelX, int pixelY, int rowSeed, float t) {
	float scrollSpeed = 0.5 + float(hash_mix(uint(rowSeed) ^ 17u) & 0xFFFFu) / 65535.0 * 1.5;
	int offset = int(floor(t * scrollSpeed * 120.0));

	int sx = pixelX + offset;
	int cellX;
	if (sx >= 0) {
		cellX = sx / CELL_W;
	} else {
		cellX = (sx - CELL_W + 1) / CELL_W;
	}
	int localX = sx - cellX * CELL_W;

	uint h = hash_mix(uint(cellX) ^ (uint(rowSeed) * 997u));
	int digit = int(h % 10u);

	return sample_glyph(digit, localX, pixelY);
}

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / dims;
	vec4 src = texelFetch(inputTex, ivec2(gl_FragCoord.xy), 0);

	float t = time * speed;
	uint baseSeed = hash_mix(uint(seed) * 7919u);

	int totalH = int(rows) * (CELL_H + ROW_GAP);

	int px = int(floor(uv.x * dims.x));
	int pyFromBottom = int(floor((1.0 - uv.y) * dims.y));

	if (pyFromBottom >= totalH) {
		frag = src;
		return;
	}

	int rowStride = CELL_H + ROW_GAP;
	int rowIdx = pyFromBottom / rowStride;
	int localY = pyFromBottom - rowIdx * rowStride;

	if (rowIdx >= int(rows) || localY >= CELL_H) {
		frag = src;
		return;
	}

	int rowSeed = int(hash_mix(uint(rowIdx) + baseSeed));

	float mask = ticker_row_mask(px, localY, rowSeed, t);

	float shadow = 0.0;
	int shadowLocalY = localY + 2;
	if (shadowLocalY < CELL_H) {
		shadow = ticker_row_mask(px + 2, shadowLocalY, rowSeed, t);
	}

	vec3 result = src.rgb;
	result = result * (1.0 - shadow * 0.4 * alpha);
	result = max(result, vec3(mask) * alpha);

	frag = vec4(clamp(result, vec3(0.0), vec3(1.0)), src.a);
}

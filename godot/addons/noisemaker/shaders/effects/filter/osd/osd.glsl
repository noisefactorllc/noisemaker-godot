#version 450
// filter/osd (program "osd") — ported PIXEL-IDENTICALLY from wgsl/osd.wgsl.
// On-screen-display overlay: a 3-6 digit bank_ocr readout in one corner, time-cycling digit
// values, green/white tint over a dark panel, plus a faint full-frame scanline. Single pass.
//
// COMPUTE→RENDER: the reference authored this as a WGSL @compute shader writing a storage
// buffer; the reference AUTO-CONVERTS it to a fragment pass — the golden's graph pass outputs
// `fragColor`, and the golden actually runs reference/glsl/osd.glsl (the render form). So the
// parity target is that GLSL, and per PORTING-GUIDE "GLSL wins on divergence" the OSD PLACEMENT
// follows the GLSL, NOT the WGSL: the GLSL is authored in GL bottom-left coords (corner 3 →
// origin_y = PADDING, glyph row flipped via local_y = (CELL_H-1)-ly, scanline on the GL y).
// The compute→fragment mapping: `gid.xy`→`gl_FragCoord.xy`, storage write→`frag`. gl_FragCoord
// is TOP-LEFT here, so a GL-convention `fy = height-1-coord.y` feeds the placement/scanline/
// row logic (texelFetch still uses the true top-left coord — the image is not double-flipped).
// Porting the WGSL's top-left corner mapping instead vertically MIRRORED the panel vs golden.
// The reference GLSL's renderScale scaling of SCALE/PADDING is a no-op at renderScale=1 (the
// parity harness), so the fixed constants here are numerically identical and we don't reproduce
// that remap.
//
// No-layout effect (osd.json has NO uniformLayout): the backend SYNTHESIZES the Params UBO +
// `#define <name> data[slot].comp` for the params (alpha, seed, speed, corner) and the engine
// global `time`. Use bare names. `seed`/`speed` arrive as float (used as float here); `corner`
// is int → int(corner). The WGSL's OsdParams width/height/channels are engine-supplied: width/
// height come from textureSize(inputTex) (the pass renders at input size). `time` is the engine
// global; renamed nothing (no local collides). The `OsdParams.time` field maps to bare `time`.
//
// WGSL→GLSL: textureLoad→texelFetch (integer coord, no sampler); `v >> u32(n)`→`v >> uint(n)`;
// `coord.y & 1`→`coord.y & 1` (int bitwise). gl_FragCoord top-left/+0.5 like @position.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const int GLYPH_W = 7;
const int GLYPH_H = 8;
const int SCALE = 3;
const int CELL_W = 21;  // GLYPH_W * SCALE
const int CELL_H = 24;  // GLYPH_H * SCALE
const int GAP = 3;      // SCALE
const int PADDING = 25;

// Bank OCR bitmaps: 10 digits, 7 wide x 8 tall each
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

uint pcg(uint v_in) {
	uint state = v_in * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

uint hash2(uint a, uint b) {
	return pcg(a ^ (b * 0x9e3779b9u + 0x632be59bu));
}

uint hash3(uint a, uint b, uint c) {
	return pcg(hash2(a, b) ^ (c * 0x94d049bbu + 0x5bf03635u));
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

void main() {
	ivec2 idims = textureSize(inputTex, 0);
	uint w = max(uint(max(round(float(idims.x)), 0.0)), 1u);
	uint h = max(uint(max(round(float(idims.y)), 0.0)), 1u);

	ivec2 coord = ivec2(int(gl_FragCoord.x), int(gl_FragCoord.y));
	vec4 texel = texelFetch(inputTex, coord, 0);

	uint base_seed = uint(max(seed, 1.0));
	int width = int(w);
	int height = int(h);

	// The golden runs the reference's compute→render-converted GLSL (GL bottom-left coords +
	// one present-flip). Our pipeline applies the SAME single present-flip (snapshot flip_y),
	// so our shader's coord.y maps to the same PNG row as the golden GLSL's coord.y — i.e. the
	// two present-flips cancel and we port the reference GLSL's placement/scanline/glyph-row
	// logic VERBATIM on coord.y (corner 3 → origin_y = PADDING, local_y = (CELL_H-1)-ly). NO
	// extra flip: porting the WGSL's top-left mapping, or adding a height-1-y flip, each put the
	// panel on the wrong edge vs the golden.

	float blend_alpha = clamp(alpha, 0.0, 1.0);

	// Subtle scanline tint across entire image (OSD monitor feel)
	float scanline = 1.0 - 0.03 * blend_alpha * float(coord.y & 1);
	vec3 base_rgb = texel.rgb * scanline;

	if (blend_alpha <= 0.0) {
		frag = vec4(base_rgb.x, base_rgb.y, base_rgb.z, texel.a);
		return;
	}

	// Glyph count: 3-6 from seed
	int glyph_count = 3 + int(hash2(base_seed, 42u) % 4u);

	// Overlay dimensions
	int overlay_w = glyph_count * CELL_W + (glyph_count - 1) * GAP;
	int overlay_h = CELL_H;

	// Position based on corner (GL coords: y=0 is bottom — reference GLSL mapping). 0=TL,1=TR,2=BL,3=BR
	int corner_val = int(corner);
	int origin_x;
	int origin_y;
	if (corner_val == 0) { // top-left
		origin_x = PADDING;
		origin_y = height - overlay_h - PADDING;
	} else if (corner_val == 1) { // top-right
		origin_x = width - overlay_w - PADDING;
		origin_y = height - overlay_h - PADDING;
	} else if (corner_val == 2) { // bottom-left
		origin_x = PADDING;
		origin_y = PADDING;
	} else { // bottom-right (default)
		origin_x = width - overlay_w - PADDING;
		origin_y = PADDING;
	}
	if (origin_x < 0) {
		origin_x = 0;
	}
	if (origin_y < 0) {
		origin_y = 0;
	}

	// Expand OSD region with padding for background panel
	int panel_pad = GAP * 2;
	int panel_x0 = origin_x - panel_pad;
	int panel_y0 = origin_y - panel_pad;
	int panel_x1 = origin_x + overlay_w + panel_pad;
	int panel_y1 = origin_y + overlay_h + panel_pad;

	// Outside panel region: just scanline
	if (coord.x < panel_x0 || coord.x >= panel_x1 || coord.y < panel_y0 || coord.y >= panel_y1) {
		frag = vec4(base_rgb.x, base_rgb.y, base_rgb.z, texel.a);
		return;
	}

	// Check if pixel is in OSD glyph region
	int lx = coord.x - origin_x;
	int ly = coord.y - origin_y;

	float mask = 0.0;
	if (lx >= 0 && lx < overlay_w && ly >= 0 && ly < overlay_h) {
		int cell_stride = CELL_W + GAP;
		int glyph_idx = lx / cell_stride;
		int within_glyph_x = lx - glyph_idx * cell_stride;

		if (within_glyph_x < CELL_W && glyph_idx < glyph_count) {
			// Local Y within glyph (flip so glyph row 0 is top — reference GLSL)
			int local_y = (CELL_H - 1) - ly;

			// Time-cycling digit selection
			int time_cell = int(floor(time * max(speed, 0.001)));
			uint digit_hash = hash3(base_seed, uint(glyph_idx), uint(time_cell));
			int digit = int(digit_hash % 10u);

			mask = sample_glyph(digit, within_glyph_x, local_y);
		}
	}

	// Dark background panel behind digits
	vec3 panel_bg = base_rgb * (1.0 - 0.5 * blend_alpha);

	if (mask < 0.5) {
		frag = vec4(
			clamp(panel_bg.x, 0.0, 1.0),
			clamp(panel_bg.y, 0.0, 1.0),
			clamp(panel_bg.z, 0.0, 1.0),
			texel.a
		);
		return;
	}

	// Green/white OSD tint
	vec3 osd_color = vec3(0.7, 1.0, 0.75);
	vec3 highlight = max(panel_bg, osd_color * mask);
	vec3 blended = mix(panel_bg, highlight, blend_alpha);
	frag = vec4(
		clamp(blended.x, 0.0, 1.0),
		clamp(blended.y, 0.0, 1.0),
		clamp(blended.z, 0.0, 1.0),
		texel.a
	);
}

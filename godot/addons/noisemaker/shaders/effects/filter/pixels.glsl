#version 450
// filter/pixels — ported from wgsl/pixels.wgsl. Pixelation (retro pixel-art look):
// quantizes the sample coordinate to a grid, tile-aware (grid computed in global
// coords so blocks align across tiles; the non-tiling branch matches the simple prior
// shader). No-layout effect: the backend injects the Params UBO + `#define size …`/
// `tileOffset …`/`fullResolution …`, used here as bare names. Input at set 0, binding 1.
//
// Relies on the backend's NEAREST sampler (matching the reference's gl.NEAREST effect
// render targets): pixelation samples at block left-edges (exact texel boundaries), so
// NEAREST fetches the single enclosing texel — LINEAR would 50/50-blend two (~35/255).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	if (size < 1.0) {
		frag = texture(inputTex, uv);
		return;
	}

	float pixelSize = size;
	bool isTile = length(tileOffset) > 0.0;

	if (isTile) {
		// Local renamed from WGSL `resolution` — that name is an injected engine global
		// (`#define resolution data[0].xy`), so reusing it would not compile.
		vec2 res = (fullResolution.x > 0.0) ? fullResolution : texSize;
		float dx = pixelSize / res.x;
		float dy = pixelSize / res.y;
		// Snap on a global grid so blocks align across tiles.
		vec2 globalUV = (gl_FragCoord.xy + tileOffset) / res;
		vec2 centered = globalUV - 0.5;
		vec2 gcoord = vec2(dx * floor(centered.x / dx), dy * floor(centered.y / dy));
		gcoord = gcoord + 0.5;
		vec2 coord = (gcoord * res - tileOffset) / texSize;
		frag = texture(inputTex, coord);
		return;
	}

	// Non-tiling path (matches the simple prior shader).
	float dx = pixelSize / texSize.x;
	float dy = pixelSize / texSize.y;
	vec2 centered = uv - 0.5;
	vec2 coord = vec2(dx * floor(centered.x / dx), dy * floor(centered.y / dy));
	coord = coord + 0.5;
	frag = texture(inputTex, coord);
}

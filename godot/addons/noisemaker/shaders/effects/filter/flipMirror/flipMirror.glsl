#version 450
// filter/flipMirror — ported from wgsl/flipMirror.wgsl. Horizontal/vertical flip
// and various mirroring modes selected by the `mode` param.
// No-layout effect: the backend injects the Params UBO + `#define flipMode …`
// (synthesized layout, globals.mode.uniform = "flipMode") and engine globals, so
// we use the bare reference name directly. Input texture bound at set 0, binding 1.
//
// WGSL coord math ported VERBATIM (manipulates uv.y via 1.0 - uv.y only); the
// single present flip handles global orientation, so no per-effect Y-flip is added.
// uv is gl_FragCoord / INPUT TEXTURE size (WGSL textureDimensions), not fullResolution.
// textureSampleLevel(..., 0.0) → texture(inputTex, uv) (mip 0).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	if (int(flipMode) == 1) {
		// flip both
		uv.x = 1.0 - uv.x;
		uv.y = 1.0 - uv.y;
	} else if (int(flipMode) == 2) {
		// flip horizontal
		uv.x = 1.0 - uv.x;
	} else if (int(flipMode) == 3) {
		// flip vertical
		uv.y = 1.0 - uv.y;
	} else if (int(flipMode) == 11) {
		// mirror left to right
		if (uv.x > 0.5) {
			uv.x = 1.0 - uv.x;
		}
	} else if (int(flipMode) == 12) {
		// mirror right to left
		if (uv.x < 0.5) {
			uv.x = 1.0 - uv.x;
		}
	} else if (int(flipMode) == 13) {
		// mirror up to down
		if (uv.y > 0.5) {
			uv.y = 1.0 - uv.y;
		}
	} else if (int(flipMode) == 14) {
		// mirror down to up
		if (uv.y < 0.5) {
			uv.y = 1.0 - uv.y;
		}
	} else if (int(flipMode) == 15) {
		// mirror left to right, up to down
		if (uv.x > 0.5) {
			uv.x = 1.0 - uv.x;
		}
		if (uv.y > 0.5) {
			uv.y = 1.0 - uv.y;
		}
	} else if (int(flipMode) == 16) {
		// mirror left to right, down to up
		if (uv.x > 0.5) {
			uv.x = 1.0 - uv.x;
		}
		if (uv.y < 0.5) {
			uv.y = 1.0 - uv.y;
		}
	} else if (int(flipMode) == 17) {
		// mirror right to left, up to down
		if (uv.x < 0.5) {
			uv.x = 1.0 - uv.x;
		}
		if (uv.y > 0.5) {
			uv.y = 1.0 - uv.y;
		}
	} else if (int(flipMode) == 18) {
		// mirror right to left, down to up
		if (uv.x < 0.5) {
			uv.x = 1.0 - uv.x;
		}
		if (uv.y < 0.5) {
			uv.y = 1.0 - uv.y;
		}
	}

	frag = texture(inputTex, uv);
}

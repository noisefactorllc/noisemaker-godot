#version 450
// filter/tunnel — ported PIXEL-IDENTICALLY from wgsl/tunnel.wgsl (IQ tunnel). Maps
// each pixel to perspective-tunnel coords (selectable cross-section shape) and
// samples the input there, with optional 4-tap antialias and a center vignette. A
// COORD-RESAMPLING warp. Single render pass (progName "tunnel").
//
// No-layout effect (tunnel.json has no uniformLayout): the backend SYNTHESIZES the
// Params UBO and injects `#define shape …`/`#define scale …`/`#define speed …`/
// `#define rotation …`/`#define center …`/`#define aspectLens …`/`#define antialias
// …` (uniform fields). The WGSL struct also lists `time`, but tunnel.json has NO
// `time` param — `uniforms.time` is the engine `time` global, injected as `#define
// time …` from the engine header. Bare names; NO UBO / NO uniforms. Input texture
// bound at set 0, binding 1.
//
// COORDINATE NOTE: WGSL `uv = pos.xy / textureDimensions(inputTex)`,
// `aspectRatio = texSize.x/texSize.y`. gl_FragCoord top-left (matches WGSL); NO
// Y-flip. int params (`shape`,`aspectLens`,`antialias`) arrive as float components:
// compare `shape == 0.0` … and flags `!= 0.0`. `center` is a float param compared
// `!= 0.0` and used in arithmetic. atan2→atan (arg order copied literally:
// polygonShape uses atan(uv.x, uv.y); main uses atan(centered.y, centered.x)).
// textureSample→texture. `smod2`/`polygonShape` are this effect's own helpers
// (copied verbatim). PI/TAU verbatim. No arithmetic reassociation.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// polygonShape — verbatim from WGSL.
//   let a = atan2(uv.x, uv.y) + PI;
//   let r = TAU / f32(sides);
//   return cos(floor(0.5 + a / r) * r - a) * length(uv);
float polygonShape(vec2 uv, int sides) {
	float a = atan(uv.x, uv.y) + PI;
	float r = TAU / float(sides);
	return cos(floor(0.5 + a / r) * r - a) * length(uv);
}

// smod2 — verbatim from WGSL: return m * (0.75 - abs(fract(v) - 0.5) - 0.25);
vec2 smod2(vec2 v, float m) {
	return m * (0.75 - abs(fract(v) - 0.5) - 0.25);
}

void main() {
	vec2 texSize = vec2(textureSize(inputTex, 0));
	vec2 uv = gl_FragCoord.xy / texSize;

	// Center the coordinates. WGSL: var centered = uv - 0.5;
	vec2 centered = uv - 0.5;

	// Optional aspect ratio correction. (WGSL local `aspectRatio` is a RESERVED
	// engine name in our injection model — renamed `ar` to avoid the `#define
	// aspectRatio data[0].w` macro collision; pure symbol rename.)
	float ar = texSize.x / texSize.y;
	if (aspectLens != 0.0) {
		centered.x = centered.x * ar;
	}

	// WGSL: let a = atan2(centered.y, centered.x); var r: f32;
	float a = atan(centered.y, centered.x);
	float r;

	int shapeMode = int(shape);
	if (shapeMode == 0) {
		// Circle
		r = length(centered);
	} else if (shapeMode == 1) {
		// Triangle
		r = polygonShape(centered * 2.0, 3);
	} else if (shapeMode == 2) {
		// Rounded square (superellipse)
		vec2 p = centered * centered * centered * centered * centered * centered * centered * centered;
		r = pow(p.x + p.y, 1.0 / 8.0);
	} else if (shapeMode == 3) {
		// Square
		r = polygonShape(centered * 2.0, 4);
	} else if (shapeMode == 4) {
		// Hexagon
		r = polygonShape(centered * 2.0, 6);
	} else {
		// Octagon
		r = polygonShape(centered * 2.0, 8);
	}

	// Apply scale. WGSL: r -= uniforms.scale * 0.15;
	r -= scale * 0.15;

	// Create tunnel coordinates.
	// WGSL: smod2(vec2(0.3/r + time*speed, a/PI + time*rotation), 1.0)
	vec2 tunnelCoords = smod2(vec2(
		0.3 / r + time * speed,
		a / PI + time * rotation
	), 1.0);

	vec4 color;
	if (antialias != 0.0) {
		vec2 dx = dFdx(tunnelCoords);
		vec2 dy = dFdy(tunnelCoords);
		color = vec4(0.0);
		color += texture(inputTex, tunnelCoords + dx * -0.375 + dy * -0.125);
		color += texture(inputTex, tunnelCoords + dx *  0.125 + dy * -0.375);
		color += texture(inputTex, tunnelCoords + dx *  0.375 + dy *  0.125);
		color += texture(inputTex, tunnelCoords + dx * -0.125 + dy *  0.375);
		color = color * 0.25;
	} else {
		color = texture(inputTex, tunnelCoords);
	}

	// Center vignette: smooth falloff to hide moiré at vanishing point.
	if (center != 0.0) {
		float centerMask = smoothstep(0.0, 0.5, r);
		float amt = center / 100.0;
		if (amt < 0.0) {
			color = vec4(color.rgb * mix(1.0, centerMask, -amt), color.a);
		} else {
			color = vec4(mix(color.rgb, vec3(1.0), (1.0 - centerMask) * amt), color.a);
		}
	}

	frag = color;
}

#version 450
// synth/mandala — ported PIXEL-IDENTICALLY from wgsl/mandala.wgsl. N-fold
// symmetric mandala generator: a per-pixel mask is built by folding the polar
// angle into `symmetry` wedges and stamping a shape (petal/triangle/dot) along
// `layers` concentric rings, then mixing bg/fg colors. Single render pass, no
// texture inputs.
//
// No-layout effect (like solid.glsl / osc2d.glsl): the backend SYNTHESIZES the
// Params UBO and injects, after #version, `#define <name> data[slot].comp` for
// every engine global (resolution/time/aspectRatio/...) AND every param uniform
// (scale/rotation/thickness/smoothness/symmetry/bindu/shape/layers/layerSpacing/
// twist/shapeGrowth/fgColor/bgColor/animation/speed/pulseDepth). So we use the
// bare reference names directly and declare NO UBO and NO uniforms.
//
// Coordinate note (PORTING-GUIDE golden rule 1 + 3): the WGSL divides by the
// current render-target size (st = position.xy / u.resolution) — NOT by height,
// NOT by fullResolution — and contains NO explicit Y-flip, so we divide straight
// (gl_FragCoord.xy / resolution) with no tileOffset and no per-effect flip,
// matching the bottom-left HLSL disambiguator (fragCoord / resolution).
//
// nm_core is NOT included: mandala uses none of the shared primitives. Its own
// PI/TAU/SQRT3 and helpers (floorMod, rotate2D, sdEquilateralTriangle, fillEdge,
// mandalaMask) are inlined VERBATIM per PORTING-GUIDE rule 2. floorMod is the
// exact GLSL mod identity (a - b*floor(a/b)) but inlined as the WGSL spelled it.
// atan2(p.y, p.x) -> atan(p.y, p.x), arg order copied literally. speed is an int
// uniform, cast to float before floor() as the HLSL does.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// ---- Constants (verbatim from WGSL) -----------------------------------------
const float NMM_PI    = 3.14159265359;
const float NMM_TAU   = 6.28318530718;
const float NMM_SQRT3 = 1.7320508075688772;

const int NMM_SHAPE_PETAL    = 0;
const int NMM_SHAPE_TRIANGLE = 1;
const int NMM_SHAPE_DOT      = 2;

const int NMM_ANIM_ROTATE        = 1;
const int NMM_ANIM_PULSE         = 2;
const int NMM_ANIM_DIFFERENTIAL  = 3;
const int NMM_ANIM_COUNTERROTATE = 4;
const int NMM_ANIM_SPIRALWAVE    = 5;
const int NMM_ANIM_RIPPLE        = 6;

// ---- floorMod (GLSL-style mod, always non-negative when b > 0) --------------
// Verbatim from WGSL: a - b * floor(a / b)
float nmm_floorMod(float a, float b) {
	return a - b * floor(a / b);
}

// ---- rotate2D (mandala's own version) ---------------------------------------
// WGSL: vec2<f32>(p.x*c - p.y*s, p.x*s + p.y*c)
vec2 nmm_rotate2D(vec2 p, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// ---- sdEquilateralTriangle --------------------------------------------------
// Verbatim from WGSL.
float nmm_sdEquilateralTriangle(vec2 p_in, float r) {
	float k = NMM_SQRT3;
	vec2 p = vec2(abs(p_in.x) - r, p_in.y + r / k);
	if (p.x + k * p.y > 0.0) {
		p = vec2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
	}
	p.x = p.x - clamp(p.x, -2.0 * r, 0.0);
	return -length(p) * sign(p.y);
}

// ---- fillEdge ---------------------------------------------------------------
// WGSL: smoothstep(u.smoothness, -u.smoothness, d)
float nmm_fillEdge(float d) {
	return smoothstep(smoothness, -smoothness, d);
}

// ---- mandalaMask ------------------------------------------------------------
float nmm_mandalaMask(vec2 p) {
	float r = length(p);
	float theta = atan(p.y, p.x) - NMM_PI * 0.5;
	float wedge = NMM_TAU / float(symmetry);
	float twistRad = twist * NMM_PI / 180.0;
	float baseSize = 0.25 + thickness * 0.65;

	// spiralWave: twist oscillates over the cycle using `twist` as amplitude.
	float dynTwistRad = twistRad;
	if (animation == NMM_ANIM_SPIRALWAVE) {
		dynTwistRad = twistRad * sin(time * NMM_TAU * floor(float(speed)));
	}

	float m = 0.0;

	if (bindu != 0) {
		float dBindu = length(p) - (0.15 + thickness * 0.15);
		m = max(m, nmm_fillEdge(dBindu));
	}

	for (int i = 0; i < 12; i = i + 1) {
		if (i >= layers) { break; }
		float Rlayer = float(i + 1) * layerSpacing;

		// Per-layer animation rotation.
		float layerAnimRot = 0.0;
		if (animation == NMM_ANIM_DIFFERENTIAL) {
			layerAnimRot = time * NMM_TAU * (floor(float(speed)) + float(i));
		} else if (animation == NMM_ANIM_COUNTERROTATE) {
			float dir = 1.0;
			if (nmm_floorMod(float(i), 2.0) >= 0.5) {
				dir = -1.0;
			}
			layerAnimRot = time * NMM_TAU * floor(float(speed)) * dir;
		}

		float layerTheta = theta - float(i) * dynTwistRad - layerAnimRot;
		float folded = abs(nmm_floorMod(layerTheta + wedge * 0.5, wedge) - wedge * 0.5);
		float radial = r - Rlayer;
		float tangent = folded * Rlayer;

		float lt = 0.0;
		if (layers > 1) {
			lt = float(i) / float(layers - 1) - 0.5;
		}
		float shapeSize = baseSize * (1.0 + shapeGrowth * lt);

		// ripple: per-layer pulse with phase offset.
		if (animation == NMM_ANIM_RIPPLE) {
			shapeSize = shapeSize * (1.0 + pulseDepth * sin(time * NMM_TAU * floor(float(speed)) - float(i) * 0.6));
		}

		if (shape == NMM_SHAPE_PETAL) {
			float d = length(vec2(radial * 0.55, tangent)) - shapeSize;
			m = max(m, nmm_fillEdge(d));
		} else if (shape == NMM_SHAPE_TRIANGLE) {
			vec2 q = vec2(tangent, -radial);
			float d = nmm_sdEquilateralTriangle(q, shapeSize);
			m = max(m, nmm_fillEdge(d));
		} else {
			float d = length(vec2(radial, tangent)) - shapeSize * 0.7;
			m = max(m, nmm_fillEdge(d));
		}
	}
	return m;
}

void main() {
	// WGSL: st = position.xy / resolution  (divides by current render-target size).
	// Top-left port: divide straight, no WGSL Y-flip (there is none here anyway).
	vec2 st = gl_FragCoord.xy / resolution;
	st = (st - vec2(0.5, 0.5)) * 2.0;
	st.x = st.x * aspectRatio;

	float rad = rotation * NMM_PI / 180.0;
	st = nmm_rotate2D(st, rad);

	if (animation == NMM_ANIM_ROTATE) {
		st = nmm_rotate2D(st, time * NMM_TAU * floor(float(speed)));
	}

	float scaleFactor = 21.0 - scale;
	if (animation == NMM_ANIM_PULSE) {
		scaleFactor = scaleFactor * (1.0 + pulseDepth * sin(time * NMM_TAU * floor(float(speed))));
	}

	vec2 p = st * scaleFactor;

	float m = clamp(nmm_mandalaMask(p), 0.0, 1.0);
	vec3 color = mix(bgColor, fgColor, m);
	frag = vec4(color, 1.0);
}

#version 450
// synth/sacredGeometry — ported PIXEL-IDENTICALLY from wgsl/sacredGeometry.wgsl.
// Flower-of-life and related sacred-geometry lattices (flower, fruit, metatron,
// seed, vesica, borromean, starPolygon, triquetra). Generator, no texture inputs.
// Single render pass "sacredGeometry".
//
// No-layout effect (like solid.glsl / osc2d.glsl): the backend SYNTHESIZES the
// Params UBO and injects, after #version, `#define <name> data[slot].comp` for
// every engine global (resolution/time/aspectRatio/tileOffset/fullResolution/
// renderScale) AND every param uniform (geometry/scale/rings/starPoints/rotation/
// thickness/smoothness/fgColor/bgColor/animation/speed/pulseDepth). So we use the
// bare names directly and declare NO UBO and NO uniforms.
//
// Coordinate note: the WGSL divides position.xy / u.resolution with NO explicit
// Y-flip; gl_FragCoord is top-left in Godot/Vulkan (matches WGSL) so we divide
// straight with no per-effect flip. WGSL u.aspect == fullResolution.x/.y == the
// injected `aspectRatio` (confirmed by the HLSL disambiguator).
//
// All helpers (rotate2D, lineSegmentSDF, outlineEdge, ripplePulse, unfoldVis,
// flowerMask, fruitMask, vesicaMask, triquetraMask, borromeanMask,
// starPolygonMask) are this effect's OWN variants and are inlined VERBATIM per
// PORTING-GUIDE rule 2. No shared nm_core primitives are used, so nm_core.glsl is
// not included. PI/TAU/SQRT3 are the effect's own constants (PI/TAU differ from
// nm_core's), declared locally.

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// Local constants matching WGSL exactly (PI/TAU differ from nm_core's).
const float SG_PI    = 3.14159265359;
const float SG_TAU   = 6.28318530718;
const float SG_SQRT3 = 1.7320508075688772;

const int SG_ANIM_ROTATE = 1;
const int SG_ANIM_PULSE  = 2;
const int SG_ANIM_RIPPLE = 4;
const int SG_ANIM_UNFOLD = 5;

const int SG_GEOM_FLOWER     = 0;
const int SG_GEOM_FRUIT      = 1;
const int SG_GEOM_METATRON   = 3;
const int SG_GEOM_SEED       = 4;
const int SG_GEOM_VESICA     = 5;
const int SG_GEOM_BORROMEAN  = 6;
const int SG_GEOM_STARPOLYGON = 7;
const int SG_GEOM_TRIQUETRA  = 8;

// fn rotate2D — verbatim from WGSL
vec2 sg_rotate2D(vec2 p, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// fn lineSegmentSDF — verbatim from WGSL
float sg_lineSegmentSDF(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

// fn outlineEdge — verbatim; reads `smoothness`
float sg_outlineEdge(float d, float w) {
	return smoothstep(w + smoothness, w - smoothness, abs(d));
}

// fn ripplePulse — verbatim; reads `pulseDepth`, `time`, `speed`
float sg_ripplePulse(float phase) {
	return 1.0 + pulseDepth * sin(time * SG_TAU * floor(float(speed)) - phase);
}

// fn unfoldVis — verbatim; reads `time`, `speed`
float sg_unfoldVis(float t_e) {
	return max(0.0, sin((time - t_e * 0.5) * SG_TAU * floor(float(speed))));
}

// fn flowerMask — verbatim from WGSL
float sg_flowerMask(vec2 p_in, int ringsN, float figureScale) {
	float lineWidth = 0.04 + thickness * 0.12;
	float circleRadius = 1.0;
	vec2 p = p_in * figureScale;

	float m = 0.0;
	for (int q = -6; q <= 6; q = q + 1) {
		if (q < -ringsN || q > ringsN) { continue; }
		for (int r = -6; r <= 6; r = r + 1) {
			if (r < -ringsN || r > ringsN) { continue; }
			if (q + r < -ringsN || q + r > ringsN) { continue; }

			vec2 center = vec2(float(q) + float(r) * 0.5, float(r) * SG_SQRT3 * 0.5);
			float hexDist = max(max(abs(float(q)), abs(float(r))), abs(float(q + r)));

			float circleR = circleRadius;
			if (animation == SG_ANIM_RIPPLE) {
				circleR = circleR * sg_ripplePulse(hexDist * 1.4);
			}
			float d = length(p - center) - circleR;

			float vis = 1.0;
			if (animation == SG_ANIM_UNFOLD) {
				float t_e = hexDist / max(float(ringsN), 1.0);
				vis = sg_unfoldVis(t_e);
			}

			m = max(m, sg_outlineEdge(d, lineWidth) * vis);
		}
	}
	return m;
}

// fn fruitMask — verbatim from WGSL
float sg_fruitMask(vec2 p_in, bool drawLines) {
	float lineWidth = 0.04 + thickness * 0.12;
	vec2 p = p_in * 0.5;

	vec2 centers[13];
	centers[0] = vec2(0.0, 0.0);
	for (int k = 0; k < 6; k = k + 1) {
		float angle = float(k) * SG_PI / 3.0;
		centers[1 + k] = 2.0 * vec2(cos(angle), sin(angle));
	}
	for (int k = 0; k < 6; k = k + 1) {
		float angle = float(k) * SG_PI / 3.0 + SG_PI / 6.0;
		centers[7 + k] = 2.0 * SG_SQRT3 * vec2(cos(angle), sin(angle));
	}

	float maxCircleDist = 2.0 * SG_SQRT3;
	float circleUnfoldRange = 1.0;
	if (drawLines) {
		circleUnfoldRange = 0.6;
	}

	float m = 0.0;

	for (int i = 0; i < 13; i = i + 1) {
		float distFromOrigin = length(centers[i]);

		float circleR = 1.0;
		if (animation == SG_ANIM_RIPPLE) {
			circleR = circleR * sg_ripplePulse(distFromOrigin * 0.8);
		}
		float d = length(p - centers[i]) - circleR;

		float vis = 1.0;
		if (animation == SG_ANIM_UNFOLD) {
			float t_e = distFromOrigin / maxCircleDist * circleUnfoldRange;
			vis = sg_unfoldVis(t_e);
		}

		m = max(m, sg_outlineEdge(d, lineWidth) * vis);
	}

	if (drawLines) {
		float lineVis = 1.0;
		if (animation == SG_ANIM_UNFOLD) {
			lineVis = sg_unfoldVis(0.65);
		}
		for (int i = 0; i < 13; i = i + 1) {
			for (int j = 0; j < 13; j = j + 1) {
				if (j <= i) { continue; }
				float dL = sg_lineSegmentSDF(p, centers[i], centers[j]);
				m = max(m, sg_outlineEdge(dL, lineWidth * 0.5) * lineVis);
			}
		}
	}

	return m;
}

// fn vesicaMask — verbatim from WGSL
float sg_vesicaMask(vec2 p_in) {
	float lineWidth = 0.04 + thickness * 0.12;
	vec2 p = p_in * 0.25;
	float r = 1.5;
	float sep = r * 0.5;

	float rA = r;
	float rB = r;
	if (animation == SG_ANIM_RIPPLE) {
		rA = rA * sg_ripplePulse(0.0);
		rB = rB * sg_ripplePulse(SG_PI);
	}

	float visA = 1.0;
	float visB = 1.0;
	if (animation == SG_ANIM_UNFOLD) {
		visA = sg_unfoldVis(0.0);
		visB = sg_unfoldVis(0.5);
	}

	float dA = length(p - vec2(-sep, 0.0)) - rA;
	float dB = length(p - vec2( sep, 0.0)) - rB;

	float m = 0.0;
	m = max(m, sg_outlineEdge(dA, lineWidth) * visA);
	m = max(m, sg_outlineEdge(dB, lineWidth) * visB);
	return m;
}

// fn triquetraMask — verbatim from WGSL
float sg_triquetraMask(vec2 p_in) {
	float lineWidth = 0.04 + thickness * 0.12;
	vec2 p = p_in * 0.30;
	float r = 2.25;
	float dist = r / SG_SQRT3;

	vec2 C0 = dist * vec2(cos(SG_PI * 0.5),                     sin(SG_PI * 0.5));
	vec2 C1 = dist * vec2(cos(SG_PI * 0.5 + SG_TAU / 3.0),      sin(SG_PI * 0.5 + SG_TAU / 3.0));
	vec2 C2 = dist * vec2(cos(SG_PI * 0.5 + 2.0 * SG_TAU / 3.0), sin(SG_PI * 0.5 + 2.0 * SG_TAU / 3.0));

	float r0 = r;
	float r1 = r;
	float r2 = r;
	if (animation == SG_ANIM_RIPPLE) {
		r0 = r0 * sg_ripplePulse(0.0);
		r1 = r1 * sg_ripplePulse(SG_TAU / 3.0);
		r2 = r2 * sg_ripplePulse(2.0 * SG_TAU / 3.0);
	}

	float d0 = length(p - C0) - r0;
	float d1 = length(p - C1) - r1;
	float d2 = length(p - C2) - r2;

	float v01 = 1.0;
	float v02 = 1.0;
	float v12 = 1.0;
	if (animation == SG_ANIM_UNFOLD) {
		v01 = sg_unfoldVis(0.0);
		v02 = sg_unfoldVis(0.33);
		v12 = sg_unfoldVis(0.66);
	}

	float m = 0.0;
	m = max(m, sg_outlineEdge(max(d0, d1), lineWidth) * v01);
	m = max(m, sg_outlineEdge(max(d0, d2), lineWidth) * v02);
	m = max(m, sg_outlineEdge(max(d1, d2), lineWidth) * v12);
	return m;
}

// fn borromeanMask — verbatim from WGSL
float sg_borromeanMask(vec2 p_in) {
	float lineWidth = 0.04 + thickness * 0.12;
	vec2 p = p_in * 0.32;
	float r = 1.5;
	float dist = 1.4;

	float m = 0.0;
	for (int i = 0; i < 3; i = i + 1) {
		float angle = float(i) * SG_TAU / 3.0 + SG_PI * 0.5;
		vec2 c = dist * vec2(cos(angle), sin(angle));

		float circleR = r;
		if (animation == SG_ANIM_RIPPLE) {
			circleR = circleR * sg_ripplePulse(float(i) * SG_TAU / 3.0);
		}
		float d = length(p - c) - circleR;

		float vis = 1.0;
		if (animation == SG_ANIM_UNFOLD) {
			vis = sg_unfoldVis(float(i) / 3.0);
		}

		m = max(m, sg_outlineEdge(d, lineWidth) * vis);
	}
	return m;
}

// fn starPolygonMask — verbatim from WGSL
float sg_starPolygonMask(vec2 p_in, int n) {
	float lineWidth = 0.04 + thickness * 0.12;
	vec2 p = p_in * 0.32;
	float radius = 2.8;

	if (animation == SG_ANIM_RIPPLE) {
		radius = radius * sg_ripplePulse(0.0);
	}

	float m = 0.0;
	for (int i = 0; i < 12; i = i + 1) {
		if (i >= n) { break; }
		int j = (i + 2) - ((i + 2) / n) * n;
		float angle1 = float(i) * SG_TAU / float(n) + SG_PI * 0.5;
		float angle2 = float(j) * SG_TAU / float(n) + SG_PI * 0.5;
		vec2 a = radius * vec2(cos(angle1), sin(angle1));
		vec2 b = radius * vec2(cos(angle2), sin(angle2));
		float dL = sg_lineSegmentSDF(p, a, b);

		float vis = 1.0;
		if (animation == SG_ANIM_UNFOLD) {
			vis = sg_unfoldVis(float(i) / float(n));
		}

		m = max(m, sg_outlineEdge(dL, lineWidth) * vis);
	}
	return m;
}

void main() {
	// WGSL: var st = position.xy / u.resolution
	vec2 st = gl_FragCoord.xy / resolution;
	// WGSL: st = (st - 0.5) * 2;  st.x *= aspect
	st = (st - vec2(0.5, 0.5)) * 2.0;
	st.x = st.x * aspectRatio;

	float rad = rotation * SG_PI / 180.0;
	st = sg_rotate2D(st, rad);

	if (animation == SG_ANIM_ROTATE) {
		st = sg_rotate2D(st, time * SG_TAU * floor(float(speed)));
	}

	float scaleFactor = 21.0 - scale;
	if (animation == SG_ANIM_PULSE) {
		scaleFactor = scaleFactor * (1.0 + pulseDepth * sin(time * SG_TAU * floor(float(speed))));
	}

	vec2 p = st * scaleFactor;

	float m = 0.0;
	if (geometry == SG_GEOM_FLOWER) {
		m = sg_flowerMask(p, int(rings), 0.45);
	} else if (geometry == SG_GEOM_SEED) {
		m = sg_flowerMask(p, 1, 0.23);
	} else if (geometry == SG_GEOM_FRUIT) {
		m = sg_fruitMask(p, false);
	} else if (geometry == SG_GEOM_METATRON) {
		m = sg_fruitMask(p, true);
	} else if (geometry == SG_GEOM_VESICA) {
		m = sg_vesicaMask(p);
	} else if (geometry == SG_GEOM_BORROMEAN) {
		m = sg_borromeanMask(p);
	} else if (geometry == SG_GEOM_TRIQUETRA) {
		m = sg_triquetraMask(p);
	} else if (geometry == SG_GEOM_STARPOLYGON) {
		m = sg_starPolygonMask(p, int(starPoints));
	}

	m = clamp(m, 0.0, 1.0);
	vec3 color = mix(bgColor, fgColor, m);
	frag = vec4(color, 1.0);
}

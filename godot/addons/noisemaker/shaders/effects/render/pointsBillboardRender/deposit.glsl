#version 450
// render/pointsBillboardRender — program "deposit" FRAGMENT stage (paint each billboard
// quad with an SDF shape or sprite texture). Ported from glsl/deposit.frag. shapeMode 0
// samples spriteTex; 1-6 are analytic SDF shapes (circle/ring/square/diamond/triangle/star);
// 7 (soft) is a gaussian falloff. depositOpacity scales the deposited intensity. Additive
// ONE,ONE blend is configured by the backend for this blend:true pass.
//
// Layout effect: vec4 data[4] (uniformLayouts.deposit): shapeMode=data[3].z,
// depositOpacity=data[3].w (shared Params block with the vertex stage). Sampler: spriteTex=3.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[4]; };
#define shapeMode int(data[3].z)
#define depositOpacity data[3].w
layout(set = 0, binding = 3) uniform sampler2D spriteTex;

layout(location = 0) in vec4 vColor;
layout(location = 1) in vec2 vSpriteUV;
layout(location = 0) out vec4 fragColor;

void main() {
	float opacity = depositOpacity / 100.0;

	if (shapeMode == 0) {
		// Texture mode: sample sprite texture
		vec4 spriteColor = texture(spriteTex, vSpriteUV);
		fragColor = vec4(spriteColor.rgb * vColor.rgb, spriteColor.a * vColor.a) * opacity;
	} else {
		// Procedural SDF shapes
		vec2 p = vSpriteUV - 0.5;
		float sdf;
		float alpha;

		if (shapeMode == 1) {
			// Circle
			sdf = length(p) - 0.45;
		} else if (shapeMode == 2) {
			// Ring
			sdf = abs(length(p) - 0.35) - 0.08;
		} else if (shapeMode == 3) {
			// Square
			sdf = max(abs(p.x), abs(p.y)) - 0.4;
		} else if (shapeMode == 4) {
			// Diamond
			sdf = abs(p.x) + abs(p.y) - 0.45;
		} else if (shapeMode == 5) {
			// Equilateral triangle (Inigo Quilez SDF)
			float r = 0.25;
			float k = 1.732050808; // sqrt(3)
			vec2 t = vec2(abs(p.x) - r, p.y - 0.04 + r / k);
			if (t.x + k * t.y > 0.0) t = vec2(t.x - k * t.y, -k * t.x - t.y) / 2.0;
			t.x -= clamp(t.x, -2.0 * r, 0.0);
			sdf = -length(t) * sign(t.y);
		} else if (shapeMode == 6) {
			// 5-point star (Inigo Quilez SDF — straight edges)
			float r = 0.35;
			float rf = 0.4;
			vec2 k1 = vec2(0.809016994375, -0.587785252292);
			vec2 k2 = vec2(-k1.x, k1.y);
			vec2 s = vec2(abs(p.x), p.y);
			s -= 2.0 * max(dot(k1, s), 0.0) * k1;
			s -= 2.0 * max(dot(k2, s), 0.0) * k2;
			s.x = abs(s.x);
			s.y -= r;
			vec2 ba = rf * vec2(-k1.y, k1.x) - vec2(0.0, 1.0);
			float h = clamp(dot(s, ba) / dot(ba, ba), 0.0, r);
			sdf = length(s - ba * h) * sign(s.y * ba.x - s.x * ba.y);
		} else {
			// Soft (7) — gaussian falloff
			alpha = exp(-dot(p, p) * 8.0);
			fragColor = vec4(vColor.rgb * alpha, alpha * vColor.a) * opacity;
			return;
		}

		alpha = 1.0 - smoothstep(-0.02, 0.02, sdf);
		fragColor = vec4(vColor.rgb * alpha, alpha * vColor.a) * opacity;
	}
}

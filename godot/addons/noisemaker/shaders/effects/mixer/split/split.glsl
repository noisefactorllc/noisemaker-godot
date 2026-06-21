#version 450
// mixer/split — ported PIXEL-IDENTICALLY from wgsl/split.wgsl. Wipes/splits between
// two inputs (colorA = inputTex, colorB = tex) along a rotatable line that can animate
// across the screen. Single render pass; only built-in math (cos/sin/fract/floor/
// smoothstep/mix/max), nothing hoisted. No-layout effect: backend injects Params UBO +
// `#define position …`/`rotation …`/`softness …`/`invert …`/`speed …` and engine names
// `time`/`tileOffset`/`fullResolution`. Two inputs (pass.inputs order):
//   inputTex = colorA / source A (binding 1), tex = colorB / source B (binding 2).
// Sample coord: WGSL divides pos.xy by inputTex's OWN dims for BOTH textures (same st).
// speed is typed `int` in the def but the WGSL binds it as f32 and tests `speed > 0.0`;
// the injected define is a float component, so bare `speed` already matches the WGSL.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D tex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

// PI — matches WGSL: `const PI: f32 = 3.14159265359;`
const float PI = 3.14159265359;

void main() {
	vec2 dims = vec2(textureSize(inputTex, 0));
	vec2 st = gl_FragCoord.xy / dims;

	vec4 colorA = texture(inputTex, st);
	vec4 colorB = texture(tex, st);

	vec2 globalUV = (gl_FragCoord.xy + tileOffset) / fullResolution;
	float aspect = fullResolution.x / fullResolution.y;
	vec2 centered = (globalUV - vec2(0.5, 0.5)) * 2.0;
	centered.x = centered.x * aspect;

	// Rotate the split line
	float rad = rotation * PI / 180.0;
	float c = cos(rad);
	float s = sin(rad);
	vec2 rotated = vec2(centered.x * c - centered.y * s,
	                    centered.x * s + centered.y * c);

	// Compute visible extent of rotated.y for seamless scrolling
	// The projected range depends on aspect ratio and rotation angle
	float extent = aspect * abs(s) + abs(c) + softness;

	// Animate: continuous scroll across full visible range
	// Alternates sweep direction each cycle so the wrap point is seamless
	float animPos = position;
	bool flipCycle = false;
	if (speed > 0.0) {
		float cycle = time * speed * 2.0;
		float t = fract(cycle);
		flipCycle = int(floor(cycle)) % 2 == 1;
		animPos = t * extent * 2.0 - extent;
	}

	// Signed distance from the split line
	float d = rotated.y - animPos;

	// Apply softness
	float halfSoft = max(softness * 0.5, 0.001);
	float mask = smoothstep(-halfSoft, halfSoft, d);

	if ((int(invert) == 1) != flipCycle) {
		mask = 1.0 - mask;
	}

	vec4 color = mix(colorA, colorB, mask);
	color.a = max(colorA.a, colorB.a);

	frag = color;
}

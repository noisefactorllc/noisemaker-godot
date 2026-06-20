#version 450
// filter/invert (program "inv") — ported from wgsl/inv.wgsl, pixel-identically.
// Simple RGB inversion: out.rgb = 1.0 - color.rgb, alpha passed through.
//
// LAYOUT effect: effects/filter/invert.json declares a uniformLayout (empty {}),
// so the backend does NOT inject a synthesized header — this shader declares its
// own UBO. With an empty layout the packed UBO is one vec4 (max slot 0 + 1), so
// `vec4 data[1]`; the WGSL reads no params, so data[] is unused but must be
// declared to match the UBO the backend always binds at set 0, binding 0.
//
// FILTER: samples the input texture, bound at set 0, binding 1 (pass.inputs
// order — `inputTex` is the only input). uv = gl_FragCoord.xy / input texture
// size (WGSL divides by textureDimensions(inputTex), not fullResolution).
// gl_FragCoord is top-left in Godot/Vulkan (matches WGSL @builtin(position));
// no per-effect Y-flip. No shared primitives → nm_core not included.
layout(set = 0, binding = 0, std140) uniform Params { vec4 data[1]; };
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	// WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
	vec2 texSize = vec2(textureSize(inputTex, 0));
	// WGSL: let uv = pos.xy / texSize;
	vec2 uv = gl_FragCoord.xy / texSize;
	// WGSL: var color = textureSample(inputTex, inputSampler, uv);
	vec4 color = texture(inputTex, uv);

	// WGSL: color = vec4<f32>(1.0 - color.rgb, color.a);
	color = vec4(1.0 - color.rgb, color.a);

	frag = color;
}

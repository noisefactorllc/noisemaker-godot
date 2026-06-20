#version 450
// synth/bitwise — ported PIXEL-IDENTICALLY from wgsl/bitwise.wgsl (top-left origin =
// Godot/Vulkan, no Y-flip). Bitwise/arithmetic operation patterns (XOR squares, AND,
// OR, etc.) with rotation, animation, and mono/rgb/hsv color modes.
// Packed uniformLayout: vec4 data[6] (effects/synth/bitwise.json, max slot 5).
// Uses no shared primitives — this effect's PI is 3.14159265358979 (NOT full precision)
// and it carries its own hsv2rgb/bitOp; inline verbatim, no nm_core include.

layout(set = 0, binding = 0, std140) uniform Params { vec4 data[6]; };
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const float PI = 3.14159265358979;

// Branchless HSV to RGB conversion
vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, vec3(0.0), vec3(1.0)), vec3(c.y));
}

// Perform the selected bitwise/arithmetic operation on two integers,
// mask the result, then normalize to 0..1
float bitOp(int a, int b, int op, int m) {
	int r = 0;
	if (op == 0)      { r = a ^ b; }        // xor
	else if (op == 1) { r = a & b; }        // and
	else if (op == 2) { r = a | b; }        // or
	else if (op == 3) { r = ~(a & b); }     // nand
	else if (op == 4) { r = ~(a ^ b); }     // xnor
	else if (op == 5) { r = a * b; }        // mul
	else if (op == 6) { r = a + b; }        // add
	else              { r = a - b; }        // sub
	r = r & m;
	return float(r) / float(m);
}

void main() {
	// Unpack uniforms
	vec2 resolution = data[0].xy;
	float time = data[0].z;
	int operation = int(data[0].w);
	float scale = data[1].x;
	int offsetX = int(data[1].y);
	int offsetY = int(data[1].z);
	int mask = int(data[1].w);
	int seed = int(data[2].x);
	int colorMode = int(data[2].y);
	int speed = int(data[2].z);
	float rotation = data[2].w;
	int colorOffset = int(data[3].x);
	vec2 tileOffset = data[4].xy;
	vec2 fullResolution = data[4].zw;
	float renderScale = data[5].x;

	// Map scale so higher value = bigger cells (lower frequency)
	float pixelScale = scale * 0.1 * renderScale;

	// Apply rotation around screen center
	float angle = rotation * PI / 180.0;
	float c = cos(angle);
	float s = sin(angle);
	vec2 centered = (gl_FragCoord.xy + tileOffset) - fullResolution * 0.5;
	vec2 rotated = vec2(centered.x * c - centered.y * s, centered.x * s + centered.y * c);
	vec2 coord = rotated + fullResolution * 0.5;

	// Time offset — uses 256 (pattern period) so it loops seamlessly at any speed
	int animOffset = int(floor(time * float(-speed) * 256.0));

	// Compute integer coordinates
	int x = int(floor(coord.x / pixelScale)) + offsetX + animOffset;
	int y = int(floor(coord.y / pixelScale)) + offsetY;

	// Seed XORs into coordinates (dramatic pattern shifts)
	x = x ^ seed;
	y = y ^ (seed * 3);

	if (colorMode == 0) {
		// Mono: same operation across all channels
		float v = bitOp(x, y, operation, mask);
		frag = vec4(v, v, v, 1.0);
	} else if (colorMode == 1) {
		// RGB: channel-shifted patterns (chromatic aberration)
		float r = bitOp(x, y, operation, mask);
		float g = bitOp(x + colorOffset, y, operation, mask);
		float b = bitOp(x, y + colorOffset, operation, mask);
		frag = vec4(r, g, b, 1.0);
	} else {
		// HSV: bitwise value drives hue, full saturation and value
		// Scale hue to avoid wrapping both ends to red
		float v = bitOp(x, y, operation, mask);
		float hueScale = float(mask) / float(mask + 1);
		frag = vec4(hsv2rgb(vec3(v * hueScale, 1.0, 1.0)), 1.0);
	}
}

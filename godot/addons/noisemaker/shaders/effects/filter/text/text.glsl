#version 450
// filter/text (program "text") — ported PIXEL-IDENTICALLY from wgsl/text.wgsl.
// Blends a pre-rendered text overlay over the input with an optional matte background.
// Single fragment pass.
//
// NOTE ON TEXT TEXTURE: the text overlay (`textTex`) is produced on the CPU — the UI renders
// the user's string to a hidden 2D canvas bound to textTex (externalTexture). There is NO GPU
// program to port for the glyphs. In the headless parity harness (and any pipeline driving
// render() directly) that canvas is absent, so textTex is the empty/zero-cleared texture:
// textPresence = text.a = 0, and this blend becomes input ⊕ matte (pure input pass-through when
// matteOpacity defaults to 0). The GLSL below is a faithful port of the only GPU program; real
// text needs the CPU canvas.
//
// MULTI-INPUT, no-layout effect (text.json has NO uniformLayout). Two inputs in pass.inputs
// order: inputTex = base (binding 1), textTex = CPU text overlay (binding 2). The backend
// SYNTHESIZES the Params UBO + `#define <name> data[slot].comp`; only matteColor (color/vec3)
// and matteOpacity (float) have a `uniform` key, so only those two are packed (the string/
// number globals text/font/size/pos*/rotation/color/justify have uniform:None and are skipped —
// no collisions). The pass wires uniforms.matteColor/matteOpacity, so the bare names are
// `matteColor`/`matteOpacity`.
//
// WGSL→GLSL: textureDimensions→textureSize; textureSample→texture; max(uvec2,uvec2) kept.
// gl_FragCoord is top-left/+0.5 like @position — NO Y-flip. Local `text` shadows nothing (the
// `text` param has uniform:None so no `#define text` is injected).
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(set = 0, binding = 2) uniform sampler2D textTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

void main() {
	uvec2 size = max(uvec2(textureSize(inputTex, 0)), uvec2(1u, 1u));
	vec2 uv = gl_FragCoord.xy / vec2(size);

	vec4 inputColor = texture(inputTex, uv);
	vec4 text = texture(textTex, uv);

	// Text presence from canvas alpha (1.0 where text exists, 0.0 elsewhere)
	float textPresence = text.a;
	float matteAlpha = matteOpacity;

	// Premultiplied blend (matches pointsRender)
	vec3 rgb = text.rgb * textPresence
			+ inputColor.rgb * (1.0 - textPresence) * (1.0 - matteAlpha)
			+ matteColor * matteAlpha * (1.0 - textPresence);

	// Alpha: text=opaque, elsewhere blend input alpha toward opaque by matte
	float alpha = max(textPresence, mix(inputColor.a, 1.0, matteAlpha));

	frag = vec4(rgb, alpha);
}

#version 450
// filter/tint (program colorize) — ported from wgsl/colorize.wgsl. Colorize input
// texture with a color overlay (overlay/multiply/recolor modes).
// No-layout effect: the backend injects the Params UBO + `#define color …` (vec3 →
// data[slot].xyz), `#define alpha …`, `#define mode …` (synthesized layout) and
// engine globals, so we use the bare reference names directly. The injected `color`
// is a vec3; the per-pixel sample is kept under `base` to avoid the collision.
// Input texture bound at set 0, binding 1.
layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

vec3 rgb_to_hsv(vec3 rgb) {
    float r = rgb.x; float g = rgb.y; float b = rgb.z;
    float max_c = max(max(r, g), b);
    float min_c = min(min(r, g), b);
    float delta = max_c - min_c;
    float hue = 0.0;
    if (delta != 0.0) {
        if (max_c == r) {
            float raw = (g - b) / delta;
            raw = raw - floor(raw / 6.0) * 6.0;
            if (raw < 0.0) { raw = raw + 6.0; }
            hue = raw;
        } else if (max_c == g) {
            hue = (b - r) / delta + 2.0;
        } else {
            hue = (r - g) / delta + 4.0;
        }
    }
    hue = hue / 6.0;
    if (hue < 0.0) { hue = hue + 1.0; }
    float sat = 0.0;
    if (max_c != 0.0) { sat = delta / max_c; }
    return vec3(hue, sat, max_c);
}

vec3 hsv_to_rgb(vec3 hsv) {
    float h = hsv.x; float s = hsv.y; float v = hsv.z;
    float dh = h * 6.0;
    float dr = clamp(abs(dh - 3.0) - 1.0, 0.0, 1.0);
    float dg = clamp(-abs(dh - 2.0) + 2.0, 0.0, 1.0);
    float db = clamp(-abs(dh - 4.0) + 2.0, 0.0, 1.0);
    float oms = 1.0 - s;
    return vec3((oms + s * dr) * v, (oms + s * dg) * v, (oms + s * db) * v);
}

void main() {
    ivec2 size = max(textureSize(inputTex, 0), ivec2(1, 1));
    vec2 st = gl_FragCoord.xy / vec2(size);
    vec4 base = textureLod(inputTex, st, 0.0);
    vec3 base_rgb = clamp(base.rgb, vec3(0.0), vec3(1.0));

    int m = int(mode);
    vec3 tinted;
    if (m == 1) {
        // Multiply
        tinted = base_rgb * color;
    } else if (m == 2) {
        // Recolor: replace hue with tint color's hue
        float tintHue = rgb_to_hsv(color).x;
        vec3 base_hsv = rgb_to_hsv(base_rgb);
        tinted = clamp(hsv_to_rgb(vec3(tintHue, clamp(base_rgb.y, 0.0, 1.0), clamp(base_hsv.z, 0.0, 1.0))), vec3(0.0), vec3(1.0));
    } else {
        // Overlay (default)
        tinted = color;
    }

    vec3 rgb = mix(base_rgb, tinted, vec3(alpha));
    frag = vec4(rgb, base.a);
}

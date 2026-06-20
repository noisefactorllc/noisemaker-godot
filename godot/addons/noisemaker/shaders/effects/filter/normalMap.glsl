#version 450
// filter/normalMap — ported from glsl/normalMap.glsl (the parity golden).
// Normal map generation via a 3x3 Sobel filter. Each pixel reads 9 neighbours
// with wrap-around addressing (texelFetch / integer coords), computes the
// horizontal and vertical Sobel responses, and encodes them into RGB normal-map
// channels with a stylised Z component.
//
// No-layout effect (globals: {}, no params): backend injects the Params UBO +
// engine globals. Input texture bound at set 0, binding 1 (pass.inputs order).
//
// PORTING NOTES:
//  * The canonical WGSL (wgsl/normalMap.wgsl) and the reference GLSL DIVERGE for
//    this effect, and the parity golden is rendered by the GLSL backend. We MUST
//    match the GLSL: encoding uses scale 0.5, a NON-inverted X, and a magnitude Z
//    that varies in [0,1]. (The WGSL uses 0.25, an inverted X, and a >=1 Z.) This
//    matches the Unity HLSL port's note. The Sobel/value-map computation is
//    identical in both sources.
//  * Reads use texelFetch (exact integer texel fetch, no interpolation) — matching
//    the golden's texelFetch; NOT texture()/clamp-to-edge, which would differ at
//    borders where wrap_coord wraps. gl_FragCoord.xy is truncated to the integer
//    pixel index (matching the golden's uvec3(uint(gl_FragCoord.x), ...)).
//  * channelCount = sanitize_channelCount(size.z). The graph passes no `size`
//    uniform, so size.z = 0 and sanitize_channelCount(0) returns 1. With
//    channelCount == 1, value_map_component returns texel.x (the RED channel) and
//    the oklab/srgb/cbrt path is never taken. We compute it through the verbatim
//    dispatch with channelCount hard-wired to 1 (size.x/y = 0 in the golden too,
//    so width/height fall back to textureSize).

layout(set = 0, binding = 1) uniform sampler2D inputTex;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag;

const uint CHANNEL_COUNT = 4u;
const uint CHANNEL_CAP = 4u;

const ivec2 SOBEL_OFFSETS[9] = ivec2[](
    ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
    ivec2(-1,  0), ivec2(0,  0), ivec2(1,  0),
    ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
);

const float SOBEL_X_KERNEL[9] = float[](
    0.5, 0.0, -0.5,
    1.0, 0.0, -1.0,
    0.5, 0.0, -0.5
);

const float SOBEL_Y_KERNEL[9] = float[](
    0.5, 1.0, 0.5,
    0.0, 0.0, 0.0,
   -0.5, -1.0, -0.5
);

uint as_u32(float value) {
    return uint(max(round(value), 0.0));
}

float clamp01(float value) {
    return clamp(value, 0.0, 1.0);
}

uint sanitize_channelCount(float raw_value) {
    uint count = as_u32(raw_value);
    if (count <= 1u) {
        return 1u;
    }
    if (count >= CHANNEL_CAP) {
        return CHANNEL_CAP;
    }
    return count;
}

int wrap_coord(int value, int limit) {
    if (limit <= 0) {
        return 0;
    }
    int wrapped = value % limit;
    if (wrapped < 0) {
        wrapped = wrapped + limit;
    }
    return wrapped;
}

float srgb_to_linear(float value) {
    if (value <= 0.04045) {
        return value / 12.92;
    }
    return pow((value + 0.055) / 1.055, 2.4);
}

float cbrt_safe(float value) {
    if (value == 0.0) {
        return 0.0;
    }
    float sign_value = (value >= 0.0) ? 1.0 : -1.0;
    return sign_value * pow(abs(value), 1.0 / 3.0);
}

float oklab_l_component(vec3 rgb) {
    float r = srgb_to_linear(clamp01(rgb.x));
    float g = srgb_to_linear(clamp01(rgb.y));
    float b = srgb_to_linear(clamp01(rgb.z));

    float l = 0.4121656120 * r + 0.5362752080 * g + 0.0514575653 * b;
    float m = 0.2118591070 * r + 0.6807189584 * g + 0.1074065790 * b;
    float s = 0.0883097947 * r + 0.2818474174 * g + 0.6302613616 * b;

    float l_c = cbrt_safe(l);
    float m_c = cbrt_safe(m);
    float s_c = cbrt_safe(s);

    return clamp01(0.2104542553 * l_c + 0.7936177850 * m_c - 0.0040720468 * s_c);
}

float value_map_component(vec4 texel, uint channelCount) {
    if (channelCount <= 1u) {
        return texel.x;
    }
    if (channelCount == 2u) {
        return texel.x;
    }
    if (channelCount == 3u) {
        return oklab_l_component(texel.xyz);
    }
    vec3 clamped_rgb = clamp(texel.xyz, vec3(0.0), vec3(1.0));
    return oklab_l_component(clamped_rgb);
}

float compute_reference_value(ivec2 coords, uint channelCount) {
    vec4 texel = texelFetch(inputTex, coords, 0);
    return value_map_component(texel, channelCount);
}

void main() {
    uvec3 global_id = uvec3(uint(gl_FragCoord.x), uint(gl_FragCoord.y), 0u);

    // size.x/y = 0 (no `size` uniform passed) -> fall back to textureSize.
    ivec2 dims = textureSize(inputTex, 0);
    uint width = uint(max(dims.x, 1));
    uint height = uint(max(dims.y, 1));
    if (global_id.x >= width || global_id.y >= height) {
        return;
    }

    // size.z = 0 -> sanitize_channelCount(0) == 1.
    uint channelCount = sanitize_channelCount(0.0);
    int width_i = int(width);
    int height_i = int(height);

    float dx = 0.0;
    float dy = 0.0;

    for (int i = 0; i < 9; i++) {
        ivec2 offset = SOBEL_OFFSETS[i];
        ivec2 sample_coord = ivec2(
            wrap_coord(int(global_id.x) + offset.x, width_i),
            wrap_coord(int(global_id.y) + offset.y, height_i)
        );
        float value = compute_reference_value(sample_coord, channelCount);
        dx += value * SOBEL_X_KERNEL[i];
        dy += value * SOBEL_Y_KERNEL[i];
    }

    float x_value = clamp(dx * 0.5 + 0.5, 0.0, 1.0);
    float y_value = clamp(dy * 0.5 + 0.5, 0.0, 1.0);
    float z_value = clamp(1.0 - (abs(dx) + abs(dy)) * 0.5, 0.0, 1.0);

    vec4 texel = texelFetch(inputTex, ivec2(global_id.xy), 0);
    frag = vec4(x_value, y_value, z_value, texel.w);
}

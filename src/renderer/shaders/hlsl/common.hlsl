// Common definitions shared across all HLSL shaders.
// Equivalent to common.glsl.

//----------------------------------------------------------------------------//
// Global Constant Buffer (matches Uniforms struct in shaders.zig)
//----------------------------------------------------------------------------//
cbuffer Globals : register(b1) {
    float4x4 projection_matrix;
    float2 screen_size;
    float2 cell_size;
    uint grid_size_packed_2u16;
    float4 grid_padding;
    uint padding_extend;
    float min_contrast;
    uint cursor_pos_packed_2u16;
    uint cursor_color_packed_4u8;
    uint bg_color_packed_4u8;
    uint bools;
};

// Bool flags
static const uint CURSOR_WIDE = 1u;
static const uint USE_DISPLAY_P3 = 2u;
static const uint USE_LINEAR_BLENDING = 4u;
static const uint USE_LINEAR_CORRECTION = 8u;

// Padding extend flags
static const uint EXTEND_LEFT = 1u;
static const uint EXTEND_RIGHT = 2u;
static const uint EXTEND_UP = 4u;
static const uint EXTEND_DOWN = 8u;

//----------------------------------------------------------------------------//
// Unpacking Functions
//----------------------------------------------------------------------------//

uint4 unpack4u8(uint packed_value) {
    return uint4(
        (packed_value >> 0) & 0xFF,
        (packed_value >> 8) & 0xFF,
        (packed_value >> 16) & 0xFF,
        (packed_value >> 24) & 0xFF
    );
}

uint2 unpack2u16(uint packed_value) {
    return uint2(
        (packed_value >> 0) & 0xFFFF,
        (packed_value >> 16) & 0xFFFF
    );
}

int2 unpack2i16(int packed_value) {
    return int2(
        (packed_value << 16) >> 16,
        (packed_value << 0) >> 16
    );
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

float luminance(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

float contrast_ratio(float3 color1, float3 color2) {
    float luminance1 = luminance(color1) + 0.05;
    float luminance2 = luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

float4 contrasted_color(float min_ratio, float4 fg, float4 bg) {
    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(float3(1, 1, 1), bg.rgb);
        float black_ratio = contrast_ratio(float3(0, 0, 0), bg.rgb);
        if (white_ratio > black_ratio)
            return float4(1, 1, 1, 1);
        else
            return float4(0, 0, 0, 1);
    }
    return fg;
}

float4 linearize4(float4 srgb) {
    bool3 cutoff = (srgb.rgb <= float3(0.04045, 0.04045, 0.04045));
    float3 higher = pow((srgb.rgb + float3(0.055, 0.055, 0.055)) / float3(1.055, 1.055, 1.055), float3(2.4, 2.4, 2.4));
    float3 lower = srgb.rgb / float3(12.92, 12.92, 12.92);
    return float4(cutoff ? lower : higher, srgb.a);
}

float linearize1(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

float4 unlinearize4(float4 lin) {
    bool3 cutoff = (lin.rgb <= float3(0.0031308, 0.0031308, 0.0031308));
    float3 higher = pow(lin.rgb, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) * float3(1.055, 1.055, 1.055) - float3(0.055, 0.055, 0.055);
    float3 lower = lin.rgb * float3(12.92, 12.92, 12.92);
    return float4(cutoff ? lower : higher, lin.a);
}

float unlinearize1(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

float4 load_color(uint4 in_color, bool do_linearize) {
    float4 color = float4(in_color) / float4(255.0f, 255.0f, 255.0f, 255.0f);
    if (do_linearize) color = linearize4(color);
    color.rgb *= color.a;
    return color;
}

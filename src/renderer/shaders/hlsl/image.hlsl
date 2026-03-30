// Image shader - renders embedded images (kitty image protocol, etc.)
// Pipeline: instanced quad rendering
#include "common.hlsl"

Texture2D image_tex : register(t0);
SamplerState image_sampler : register(s0);

struct VSInput {
    float2 grid_pos : GRID_POS;
    float2 cell_offset : CELL_OFFSET;
    float4 source_rect : SOURCE_RECT;
    float2 dest_size : DEST_SIZE;
    uint vid : SV_VertexID;
};

struct PSInput {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD;
};

PSInput vs_main(VSInput input) {
    PSInput output;

    int vid = input.vid;
    float2 corner;
    corner.x = (float)(vid == 1 || vid == 3);
    corner.y = (float)(vid == 2 || vid == 3);

    // Texture coordinates from source rect
    output.tex_coord = input.source_rect.xy + input.source_rect.zw * corner;

    // Normalize
    float2 tex_size;
    image_tex.GetDimensions(tex_size.x, tex_size.y);
    output.tex_coord /= tex_size;

    // Position
    float2 image_pos = (cell_size * input.grid_pos) + input.cell_offset;
    image_pos += input.dest_size * corner;
    output.position = mul(projection_matrix, float4(image_pos.xy, 1.0, 1.0));

    return output;
}

float4 ps_main(PSInput input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 rgba = image_tex.Sample(image_sampler, input.tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize4(rgba);
    }

    rgba.rgb *= float3(rgba.a, rgba.a, rgba.a);
    return rgba;
}

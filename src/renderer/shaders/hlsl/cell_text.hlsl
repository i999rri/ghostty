// Cell text shader - renders text glyphs from font atlas.
// Pipeline: instanced quad rendering with per-instance glyph data

Texture2D atlas_grayscale : register(t0);
Texture2D atlas_color : register(t1);
SamplerState atlas_sampler : register(s0);

Buffer<uint> bg_colors : register(t2);

static const uint ATLAS_GRAYSCALE = 0u;
static const uint ATLAS_COLOR = 1u;
static const uint NO_MIN_CONTRAST = 1u;
static const uint IS_CURSOR_GLYPH = 2u;

struct VSInput {
    uint2 glyph_pos : GLYPH_POS;
    uint2 glyph_size : GLYPH_SIZE;
    int2 bearings : BEARINGS;
    uint2 grid_pos : GRID_POS;
    uint4 color : COLOR;
    uint atlas : ATLAS;
    uint glyph_bools : GLYPH_BOOLS;
    uint vid : SV_VertexID;
};

struct PSInput {
    float4 position : SV_Position;
    nointerpolation uint atlas : ATLAS;
    nointerpolation float4 color : COLOR;
    nointerpolation float4 bg_color : BG_COLOR;
    nointerpolation uint is_cursor : IS_CURSOR;
    float2 tex_coord : TEXCOORD;
};

PSInput vs_main(VSInput input) {
    PSInput output;

    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    uint2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float2 cell_pos = cell_size * float2(input.grid_pos);

    int vid = input.vid;
    float2 corner;
    corner.x = (float)(vid == 1 || vid == 3);
    corner.y = (float)(vid == 2 || vid == 3);

    output.atlas = input.atlas;

    float2 size = float2(input.glyph_size);
    float2 offset = float2(input.bearings);
    offset.y = cell_size.y - offset.y;

    cell_pos = cell_pos + size * corner + offset;
    output.position = mul(projection_matrix, float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f));

    // Texture coordinate in pixels (not normalized)
    output.tex_coord = float2(input.glyph_pos) + float2(input.glyph_size) * corner;

    output.color = load_color(input.color, true);
    output.bg_color = load_color(
        unpack4u8(bg_colors[input.grid_pos.y * grid_size.x + input.grid_pos.x]),
        true
    );
    float4 global_bg = load_color(unpack4u8(bg_color_packed_4u8), true);
    output.bg_color += global_bg * float4(1.0 - output.bg_color.a, 1.0 - output.bg_color.a, 1.0 - output.bg_color.a, 1.0 - output.bg_color.a);

    if (min_contrast > 1.0f && (input.glyph_bools & NO_MIN_CONTRAST) == 0) {
        output.color = contrasted_color(min_contrast, output.color, output.bg_color);
    }

    bool is_cursor_pos = ((input.grid_pos.x == cursor_pos.x) || (cursor_wide && (input.grid_pos.x == (cursor_pos.x + 1)))) && (input.grid_pos.y == cursor_pos.y);
    if ((input.glyph_bools & IS_CURSOR_GLYPH) == 0 && is_cursor_pos) {
        output.color = load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }

    output.is_cursor = (input.glyph_bools & IS_CURSOR_GLYPH);

    return output;
}

float4 ps_main(PSInput input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0;

    // Normalize texture coordinates for sampler2D
    float2 atlas_size_gs = float2(0, 0);
    float2 atlas_size_col = float2(0, 0);
    atlas_grayscale.GetDimensions(atlas_size_gs.x, atlas_size_gs.y);
    atlas_color.GetDimensions(atlas_size_col.x, atlas_size_col.y);

    if (input.atlas == ATLAS_GRAYSCALE) {
        float4 color = input.color;
        if (!use_linear_blending) {
            color.rgb /= float3(color.a, color.a, color.a);
            color = unlinearize4(color);
            color.rgb *= float3(color.a, color.a, color.a);
        }

        float a = atlas_grayscale.Sample(atlas_sampler, input.tex_coord / atlas_size_gs).r;

        if (use_linear_correction) {
            float4 bg = input.bg_color;
            float fg_l = luminance(color.rgb);
            float bg_l = luminance(bg.rgb);
            if (abs(fg_l - bg_l) > 0.001) {
                float blend_l = linearize1(unlinearize1(fg_l) * a + unlinearize1(bg_l) * (1.0 - a));
                a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
            }
        }

        color *= a;
        return color;
    } else {
        float4 color = atlas_color.Sample(atlas_sampler, input.tex_coord / atlas_size_col);
        if (use_linear_blending) return color;
        color.rgb /= float3(color.a, color.a, color.a);
        color = unlinearize4(color);
        color.rgb *= float3(color.a, color.a, color.a);
        return color;
    }
}

// Background image shader - renders a background image behind the terminal.
// Pipeline: full screen triangle with image texture

Texture2D image_tex : register(t0);
SamplerState image_sampler : register(s0);

static const uint BG_IMAGE_POSITION = 15u;
static const uint BG_IMAGE_TL = 0u;
static const uint BG_IMAGE_TC = 1u;
static const uint BG_IMAGE_TR = 2u;
static const uint BG_IMAGE_ML = 3u;
static const uint BG_IMAGE_MC = 4u;
static const uint BG_IMAGE_MR = 5u;
static const uint BG_IMAGE_BL = 6u;
static const uint BG_IMAGE_BC = 7u;
static const uint BG_IMAGE_BR = 8u;
static const uint BG_IMAGE_FIT = 3u << 4;
static const uint BG_IMAGE_CONTAIN = 0u << 4;
static const uint BG_IMAGE_COVER = 1u << 4;
static const uint BG_IMAGE_STRETCH = 2u << 4;
static const uint BG_IMAGE_NO_FIT = 3u << 4;
static const uint BG_IMAGE_REPEAT = 1u << 6;

struct VSInput {
    float opacity : OPACITY;
    uint info : INFO;
    uint vid : SV_VertexID;
};

struct PSInput {
    float4 position : SV_Position;
    nointerpolation float4 bg_color : BG_COLOR;
    nointerpolation float2 offset : OFFSET;
    nointerpolation float2 scale : SCALE;
    nointerpolation float opacity : OPACITY;
    nointerpolation uint repeat_flag : REPEAT;
};

PSInput vs_main(VSInput input) {
    PSInput output;

    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    output.position.x = (input.vid == 2) ? 3.0 : -1.0;
    output.position.y = (input.vid == 0) ? -3.0 : 1.0;
    output.position.z = 1.0;
    output.position.w = 1.0;

    output.opacity = input.opacity;
    output.repeat_flag = input.info & BG_IMAGE_REPEAT;

    float2 scr = screen_size;
    float2 tex_size;
    image_tex.GetDimensions(tex_size.x, tex_size.y);

    float2 dest_size = tex_size;
    uint fit = input.info & BG_IMAGE_FIT;
    if (fit == BG_IMAGE_CONTAIN) {
        float s = min(scr.x / tex_size.x, scr.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_COVER) {
        float s = max(scr.x / tex_size.x, scr.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_STRETCH) {
        dest_size = scr;
    }

    float2 start = float2(0, 0);
    float2 mid = (scr - dest_size) / 2.0;
    float2 end_pos = scr - dest_size;

    float2 dest_offset = mid;
    uint pos = input.info & BG_IMAGE_POSITION;
    if (pos == BG_IMAGE_TL) dest_offset = float2(start.x, start.y);
    else if (pos == BG_IMAGE_TC) dest_offset = float2(mid.x, start.y);
    else if (pos == BG_IMAGE_TR) dest_offset = float2(end_pos.x, start.y);
    else if (pos == BG_IMAGE_ML) dest_offset = float2(start.x, mid.y);
    else if (pos == BG_IMAGE_MC) dest_offset = float2(mid.x, mid.y);
    else if (pos == BG_IMAGE_MR) dest_offset = float2(end_pos.x, mid.y);
    else if (pos == BG_IMAGE_BL) dest_offset = float2(start.x, end_pos.y);
    else if (pos == BG_IMAGE_BC) dest_offset = float2(mid.x, end_pos.y);
    else if (pos == BG_IMAGE_BR) dest_offset = float2(end_pos.x, end_pos.y);

    output.offset = dest_offset;
    output.scale = tex_size / dest_size;

    uint4 u_bg = unpack4u8(bg_color_packed_4u8);
    output.bg_color = float4(
        load_color(uint4(u_bg.rgb, 255), use_linear_blending).rgb,
        (float)u_bg.a / 255.0
    );

    return output;
}

float4 ps_main(PSInput input) : SV_Target {
    // Get texture dimensions
    uint tex_w, tex_h;
    image_tex.GetDimensions(tex_w, tex_h);
    float2 tex_size = float2(tex_w, tex_h);
    // Fallback if GetDimensions fails
    if (tex_w == 0 || tex_h == 0) tex_size = screen_size;
    float op = input.opacity;

    uint4 bg_u = unpack4u8(bg_color_packed_4u8);
    float3 bg = float3(bg_u.rgb) / 255.0;
    float bg_a = (float)bg_u.a / 255.0;

    // Cover: scale to fill, center
    float s = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
    float2 scaled = tex_size * s;
    float2 ofs = (screen_size - scaled) * 0.5;
    float2 uv = (input.position.xy - ofs) / scaled;

    float4 img = float4(0, 0, 0, 0);
    if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
        img = image_tex.Sample(image_sampler, uv);
    }

    float3 blended = lerp(bg, img.rgb, img.a * op);
    return float4(blended * bg_a, bg_a);
}

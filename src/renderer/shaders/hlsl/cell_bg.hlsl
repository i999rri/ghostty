// Cell background shader - renders per-cell background colors.
// Pipeline: full screen triangle + structured buffer for cell colors

StructuredBuffer<uint> bg_cells : register(t1);

struct VSOutput {
    float4 position : SV_Position;
};

VSOutput vs_main(uint vid : SV_VertexID) {
    VSOutput output;
    output.position.x = (vid == 2) ? 3.0 : -1.0;
    output.position.y = (vid == 0) ? -3.0 : 1.0;
    output.position.z = 1.0;
    output.position.w = 1.0;
    return output;
}

float4 ps_main(VSOutput input) : SV_Target {
    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // FragCoord in D3D11 is already upper-left origin
    int2 grid_pos = int2(floor((input.position.xy - grid_padding.wx) / cell_size));

    float4 bg = float4(0, 0, 0, 0);

    // Clamp x position
    if (grid_pos.x < 0) {
        if ((padding_extend & EXTEND_LEFT) != 0) grid_pos.x = 0;
        else return bg;
    } else if (grid_pos.x > (int)grid_size.x - 1) {
        if ((padding_extend & EXTEND_RIGHT) != 0) grid_pos.x = (int)grid_size.x - 1;
        else return bg;
    }

    // Clamp y position
    if (grid_pos.y < 0) {
        if ((padding_extend & EXTEND_UP) != 0) grid_pos.y = 0;
        else return bg;
    } else if (grid_pos.y > (int)grid_size.y - 1) {
        if ((padding_extend & EXTEND_DOWN) != 0) grid_pos.y = (int)grid_size.y - 1;
        else return bg;
    }

    float4 cell_color = load_color(
        unpack4u8(bg_cells[grid_pos.y * grid_size.x + grid_pos.x]),
        use_linear_blending
    );

    return cell_color;
}

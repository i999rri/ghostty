// Background color shader - fills the entire screen with the background color.
// Pipeline: full screen triangle (no vertex input)

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
    // TEST: fixed green color to verify shader draws
    return float4(0.0, 1.0, 0.0, 1.0);
    //bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    //return load_color(unpack4u8(bg_color_packed_4u8), use_linear_blending);
}

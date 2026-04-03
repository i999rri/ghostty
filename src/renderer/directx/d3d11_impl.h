// D3D11 implementation wrapper - C API for Zig consumption
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>

typedef struct DxDevice DxDevice;

// Device creation
DxDevice* dx_create(void* hwnd, uint32_t width, uint32_t height);
void dx_destroy(DxDevice* dev);

// Swap chain
void dx_resize(DxDevice* dev, uint32_t width, uint32_t height);
void dx_present(DxDevice* dev, bool vsync);

// Frame operations
void dx_clear(DxDevice* dev, float r, float g, float b, float a);
void dx_set_viewport(DxDevice* dev, uint32_t width, uint32_t height);

// Buffer operations
typedef struct DxBuffer DxBuffer;
DxBuffer* dx_create_buffer(DxDevice* dev, uint32_t bind_flags, uint32_t byte_size, const void* initial_data);
void dx_destroy_buffer(DxBuffer* buf);
void dx_update_buffer(DxDevice* dev, DxBuffer* buf, const void* data, uint32_t byte_size);
void dx_bind_vertex_buffer(DxDevice* dev, DxBuffer* buf, uint32_t stride, uint32_t slot);
void dx_bind_constant_buffer(DxDevice* dev, DxBuffer* buf, uint32_t slot, bool vs, bool ps);
void dx_bind_srv_buffer(DxDevice* dev, DxBuffer* buf, uint32_t slot, uint32_t element_size);

// Texture operations
typedef struct DxTexture DxTexture;
DxTexture* dx_create_texture(DxDevice* dev, uint32_t width, uint32_t height, uint32_t format, const void* data);
void dx_destroy_texture(DxTexture* tex);
void dx_update_texture_region(DxDevice* dev, DxTexture* tex, uint32_t x, uint32_t y, uint32_t w, uint32_t h, const void* data);
void dx_bind_texture(DxDevice* dev, DxTexture* tex, uint32_t slot);

// Sampler
typedef struct DxSampler DxSampler;
DxSampler* dx_create_sampler(DxDevice* dev, uint32_t filter, uint32_t address_mode);
void dx_destroy_sampler(DxSampler* samp);
void dx_bind_sampler(DxDevice* dev, DxSampler* samp, uint32_t slot);

// Shader / Pipeline
typedef struct DxPipeline DxPipeline;
DxPipeline* dx_create_pipeline(DxDevice* dev, const void* vs_bytecode, uint32_t vs_size,
                                const void* ps_bytecode, uint32_t ps_size,
                                const void* input_desc, uint32_t input_count);
void dx_destroy_pipeline(DxPipeline* pipe);
void dx_bind_pipeline(DxDevice* dev, DxPipeline* pipe);

// Draw
void dx_draw(DxDevice* dev, uint32_t vertex_count, uint32_t start, uint32_t topology);
void dx_draw_instanced(DxDevice* dev, uint32_t vertex_count, uint32_t instance_count, uint32_t start_vertex, uint32_t start_instance, uint32_t topology);

// Render target
typedef struct DxRenderTarget DxRenderTarget;
DxRenderTarget* dx_create_render_target(DxDevice* dev, uint32_t width, uint32_t height, uint32_t format);
void dx_destroy_render_target(DxRenderTarget* rt);
void dx_bind_render_target(DxDevice* dev, DxRenderTarget* rt);
void dx_bind_backbuffer(DxDevice* dev);

// Blend state
void dx_set_blend_enabled(DxDevice* dev, bool enabled);

// Query
void dx_get_backbuffer_size(DxDevice* dev, uint32_t* width, uint32_t* height);

// Shader compilation
typedef struct DxCompiledShader {
    void* bytecode;
    uint32_t size;
} DxCompiledShader;
DxCompiledShader dx_compile_shader(const char* source, uint32_t source_len,
                                    const char* entry_point, const char* target);
void dx_free_compiled_shader(DxCompiledShader shader);

// Create pipeline with CellText input layout
DxPipeline* dx_create_cell_text_pipeline(DxDevice* dev, const void* vs_bytecode, uint32_t vs_size,
                                          const void* ps_bytecode, uint32_t ps_size);

#ifdef __cplusplus
}
#endif

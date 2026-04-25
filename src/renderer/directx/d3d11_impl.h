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
// Create device from externally-owned swap chain (for SwapChainPanel).
// The device/swap_chain are borrowed — caller retains ownership.
DxDevice* dx_create_from_swap_chain(void* d3d_device, void* swap_chain, uint32_t width, uint32_t height);
void dx_destroy(DxDevice* dev);

// Swap chain
void dx_resize(DxDevice* dev, uint32_t width, uint32_t height);
void dx_present(DxDevice* dev, bool vsync);
// Returns the IDXGISwapChain1* for SwapChainPanel integration.
// Caller must NOT release — ownership stays with DxDevice.
void* dx_get_swap_chain(DxDevice* dev);

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

// State management
void dx_clear_shader_resources(DxDevice* dev);
void dx_ensure_default_sampler(DxDevice* dev);

// Query
void dx_get_backbuffer_size(DxDevice* dev, uint32_t* width, uint32_t* height);

// Specialized pipeline creation with input layouts
DxPipeline* dx_create_bg_image_pipeline(DxDevice* dev, const void* vs_bytecode, uint32_t vs_size,
                                         const void* ps_bytecode, uint32_t ps_size);
DxPipeline* dx_create_image_pipeline(DxDevice* dev, const void* vs_bytecode, uint32_t vs_size,
                                      const void* ps_bytecode, uint32_t ps_size);
DxPipeline* dx_create_cell_text_pipeline(DxDevice* dev, const void* vs_bytecode, uint32_t vs_size,
                                          const void* ps_bytecode, uint32_t ps_size);

// Per-device window resize notification (thread-safe, called from main thread)
void dx_set_window_size(DxDevice* dev, uint32_t width, uint32_t height);
void dx_get_window_size(DxDevice* dev, uint32_t* width, uint32_t* height);

// DirectComposition visibility control (safe to call while renderer is active)
void dx_set_visible(DxDevice* dev, bool visible);

// Block until DXGI is ready for the next frame. Called at frame start to
// throttle CPU based on GPU/composition pace. No-op if the swap chain was
// not created with DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT.
void dx_wait_frame_latency(DxDevice* dev);

#ifdef __cplusplus
}
#endif

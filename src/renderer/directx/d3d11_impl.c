// D3D11 implementation wrapper
// Provides a flat C API over the COM-based D3D11 interfaces for Zig consumption.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <dxgi1_2.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")

#include "d3d11_impl.h"

// Thread-safe window size (set by main thread, read by renderer thread)
static volatile uint32_t g_window_width = 0;
static volatile uint32_t g_window_height = 0;

// --- Device ---

struct DxDevice {
    ID3D11Device* device;
    ID3D11DeviceContext* context;
    IDXGISwapChain* swap_chain;
    ID3D11RenderTargetView* backbuffer_rtv;
    ID3D11BlendState* blend_on;
    ID3D11BlendState* blend_off;
    ID3D11RasterizerState* rasterizer_state;
    D3D_FEATURE_LEVEL feature_level;
    HWND hwnd;
    uint32_t bb_width;
    uint32_t bb_height;
};

static void dx_create_backbuffer_rtv(DxDevice* dev) {
    ID3D11Texture2D* back_buffer = NULL;
    IDXGISwapChain_GetBuffer(dev->swap_chain, 0, &IID_ID3D11Texture2D, (void**)&back_buffer);
    if (back_buffer) {
        ID3D11Device_CreateRenderTargetView(dev->device, (ID3D11Resource*)back_buffer, NULL, &dev->backbuffer_rtv);
        ID3D11Texture2D_Release(back_buffer);
    }
}

DxDevice* dx_create(void* hwnd, uint32_t width, uint32_t height) {
    DxDevice* dev = (DxDevice*)calloc(1, sizeof(DxDevice));
    if (!dev) return NULL;
    dev->hwnd = (HWND)hwnd;

    D3D_FEATURE_LEVEL feature_levels[] = { D3D_FEATURE_LEVEL_11_0 };
    UINT flags = 0;
#ifndef NDEBUG
    flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif

    // Create device first (without swap chain)
    HRESULT hr = D3D11CreateDevice(
        NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags,
        feature_levels, 1, D3D11_SDK_VERSION,
        &dev->device, &dev->feature_level, &dev->context);

    if (FAILED(hr)) {
        OutputDebugStringA("D3D11: CreateDevice FAILED\n");
        free(dev);
        return NULL;
    }

    // Create swap chain via DXGI 1.2 for DXGI_SCALING_NONE (prevents DWM stretching on resize)
    IDXGIDevice* dxgi_device = NULL;
    IDXGIAdapter* adapter = NULL;
    IDXGIFactory2* factory = NULL;
    ID3D11Device_QueryInterface(dev->device, &IID_IDXGIDevice, (void**)&dxgi_device);
    IDXGIDevice_GetAdapter(dxgi_device, &adapter);
    IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory2, (void**)&factory);

    DXGI_SWAP_CHAIN_DESC1 scd = {0};
    scd.Width = width;
    scd.Height = height;
    scd.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    scd.SampleDesc.Count = 1;
    scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.BufferCount = 2;
    scd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    scd.Scaling = DXGI_SCALING_NONE;

    IDXGISwapChain1* swap_chain1 = NULL;
    hr = IDXGIFactory2_CreateSwapChainForHwnd(factory, (IUnknown*)dev->device, dev->hwnd, &scd, NULL, NULL, &swap_chain1);

    IDXGIFactory2_Release(factory);
    IDXGIAdapter_Release(adapter);
    IDXGIDevice_Release(dxgi_device);

    if (FAILED(hr) || !swap_chain1) {
        OutputDebugStringA("D3D11: CreateSwapChainForHwnd FAILED\n");
        ID3D11DeviceContext_Release(dev->context);
        ID3D11Device_Release(dev->device);
        free(dev);
        return NULL;
    }

    // Get IDXGISwapChain from IDXGISwapChain1
    IDXGISwapChain1_QueryInterface(swap_chain1, &IID_IDXGISwapChain, (void**)&dev->swap_chain);
    IDXGISwapChain1_Release(swap_chain1);
    OutputDebugStringA("D3D11: Device created successfully\n");

    dx_create_backbuffer_rtv(dev);
    dev->bb_width = width;
    dev->bb_height = height;

    // Create blend states
    D3D11_BLEND_DESC bd = {0};
    bd.RenderTarget[0].BlendEnable = TRUE;
    bd.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
    bd.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    bd.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    ID3D11Device_CreateBlendState(dev->device, &bd, &dev->blend_on);

    bd.RenderTarget[0].BlendEnable = FALSE;
    ID3D11Device_CreateBlendState(dev->device, &bd, &dev->blend_off);

    // Create rasterizer state with no culling (full-screen triangles have CCW winding in screen space)
    D3D11_RASTERIZER_DESC rd = {0};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.FrontCounterClockwise = FALSE;
    rd.DepthClipEnable = TRUE;
    rd.ScissorEnable = FALSE;
    rd.MultisampleEnable = FALSE;
    rd.AntialiasedLineEnable = FALSE;
    ID3D11Device_CreateRasterizerState(dev->device, &rd, &dev->rasterizer_state);
    if (dev->rasterizer_state) {
        ID3D11DeviceContext_RSSetState(dev->context, dev->rasterizer_state);
    }

    return dev;
}

void dx_destroy(DxDevice* dev) {
    if (!dev) return;
    if (dev->rasterizer_state) ID3D11RasterizerState_Release(dev->rasterizer_state);
    if (dev->blend_off) ID3D11BlendState_Release(dev->blend_off);
    if (dev->blend_on) ID3D11BlendState_Release(dev->blend_on);
    if (dev->backbuffer_rtv) ID3D11RenderTargetView_Release(dev->backbuffer_rtv);
    if (dev->swap_chain) IDXGISwapChain_Release(dev->swap_chain);
    if (dev->context) ID3D11DeviceContext_Release(dev->context);
    if (dev->device) ID3D11Device_Release(dev->device);
    free(dev);
}

void dx_resize(DxDevice* dev, uint32_t width, uint32_t height) {
    if (!dev || width == 0 || height == 0) return;
    if (dev->bb_width == width && dev->bb_height == height) return;

    // Clear all state that references the backbuffer
    ID3D11ShaderResourceView* nullSRVs[8] = {0};
    ID3D11DeviceContext_PSSetShaderResources(dev->context, 0, 8, nullSRVs);
    ID3D11DeviceContext_VSSetShaderResources(dev->context, 0, 8, nullSRVs);
    ID3D11DeviceContext_OMSetRenderTargets(dev->context, 0, NULL, NULL);

    if (dev->backbuffer_rtv) {
        ID3D11RenderTargetView_Release(dev->backbuffer_rtv);
        dev->backbuffer_rtv = NULL;
    }

    ID3D11DeviceContext_Flush(dev->context);

    HRESULT hr = IDXGISwapChain_ResizeBuffers(dev->swap_chain, 0, width, height, DXGI_FORMAT_UNKNOWN, 0);
    if (SUCCEEDED(hr)) {
        dx_create_backbuffer_rtv(dev);
        dev->bb_width = width;
        dev->bb_height = height;
    }
}

void dx_present(DxDevice* dev, bool vsync) {
    if (!dev) return;
    IDXGISwapChain_Present(dev->swap_chain, vsync ? 1 : 0, 0);
}

void dx_clear(DxDevice* dev, float r, float g, float b, float a) {
    if (!dev || !dev->backbuffer_rtv) return;
    float color[4] = { r, g, b, a };
    ID3D11DeviceContext_ClearRenderTargetView(dev->context, dev->backbuffer_rtv, color);
}

void dx_set_viewport(DxDevice* dev, uint32_t width, uint32_t height) {
    if (!dev) return;
    D3D11_VIEWPORT vp = { 0, 0, (float)width, (float)height, 0.0f, 1.0f };
    ID3D11DeviceContext_RSSetViewports(dev->context, 1, &vp);
}

void dx_bind_backbuffer(DxDevice* dev) {
    if (!dev) return;
    ID3D11DeviceContext_OMSetRenderTargets(dev->context, 1, &dev->backbuffer_rtv, NULL);
}

void dx_set_blend_enabled(DxDevice* dev, bool enabled) {
    if (!dev) return;
    float blend_factor[4] = { 0, 0, 0, 0 };
    ID3D11DeviceContext_OMSetBlendState(dev->context, enabled ? dev->blend_on : dev->blend_off, blend_factor, 0xFFFFFFFF);
}

void dx_clear_shader_resources(DxDevice* dev) {
    if (!dev) return;
    ID3D11ShaderResourceView* nullSRVs[8] = {0};
    ID3D11DeviceContext_VSSetShaderResources(dev->context, 0, 8, nullSRVs);
    ID3D11DeviceContext_PSSetShaderResources(dev->context, 0, 8, nullSRVs);
}

static ID3D11SamplerState* default_sampler = NULL;
void dx_ensure_default_sampler(DxDevice* dev) {
    if (!dev || default_sampler) return;
    D3D11_SAMPLER_DESC sd = {0};
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    ID3D11Device_CreateSamplerState(dev->device, &sd, &default_sampler);
    if (default_sampler) {
        ID3D11DeviceContext_PSSetSamplers(dev->context, 0, 1, &default_sampler);
    }
}

void dx_get_backbuffer_size(DxDevice* dev, uint32_t* width, uint32_t* height) {
    if (!dev) { *width = 0; *height = 0; return; }
    *width = dev->bb_width;
    *height = dev->bb_height;
}

// --- Buffer ---

struct DxBuffer {
    ID3D11Buffer* buffer;
    ID3D11ShaderResourceView* srv;  // For structured buffers
    uint32_t byte_size;
};

DxBuffer* dx_create_buffer(DxDevice* dev, uint32_t bind_flags, uint32_t byte_size, const void* initial_data) {
    if (!dev) return NULL;
    DxBuffer* buf = (DxBuffer*)calloc(1, sizeof(DxBuffer));
    if (!buf) return NULL;
    buf->byte_size = byte_size;

    D3D11_BUFFER_DESC bd = {0};
    bd.ByteWidth = byte_size;
    bd.BindFlags = bind_flags;
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;

    // Shader resource buffers: use typed buffer (not structured)
    // to avoid BUFFER_STRUCTURED compatibility issues

    D3D11_SUBRESOURCE_DATA sd = { .pSysMem = initial_data };
    HRESULT hr = ID3D11Device_CreateBuffer(dev->device, &bd, initial_data ? &sd : NULL, &buf->buffer);
    if (FAILED(hr)) { free(buf); return NULL; }

    return buf;
}

void dx_destroy_buffer(DxBuffer* buf) {
    if (!buf) return;
    if (buf->srv) ID3D11ShaderResourceView_Release(buf->srv);
    if (buf->buffer) ID3D11Buffer_Release(buf->buffer);
    free(buf);
}

void dx_update_buffer(DxDevice* dev, DxBuffer* buf, const void* data, uint32_t byte_size) {
    if (!dev || !buf || !data) return;
    D3D11_MAPPED_SUBRESOURCE mapped;
    HRESULT hr = ID3D11DeviceContext_Map(dev->context, (ID3D11Resource*)buf->buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
    if (SUCCEEDED(hr)) {
        memcpy(mapped.pData, data, byte_size < buf->byte_size ? byte_size : buf->byte_size);
        ID3D11DeviceContext_Unmap(dev->context, (ID3D11Resource*)buf->buffer, 0);
    }
}

void dx_bind_vertex_buffer(DxDevice* dev, DxBuffer* buf, uint32_t stride, uint32_t slot) {
    if (!dev || !buf) return;
    UINT offset = 0;
    ID3D11DeviceContext_IASetVertexBuffers(dev->context, slot, 1, &buf->buffer, &stride, &offset);
}

void dx_bind_constant_buffer(DxDevice* dev, DxBuffer* buf, uint32_t slot, bool vs, bool ps) {
    if (!dev || !buf) return;
    if (vs) ID3D11DeviceContext_VSSetConstantBuffers(dev->context, slot, 1, &buf->buffer);
    if (ps) ID3D11DeviceContext_PSSetConstantBuffers(dev->context, slot, 1, &buf->buffer);
}

void dx_bind_srv_buffer(DxDevice* dev, DxBuffer* buf, uint32_t slot, uint32_t element_size) {
    if (!dev || !buf) return;
    // Create SRV if not exists
    if (!buf->srv) {
        D3D11_SHADER_RESOURCE_VIEW_DESC srv_desc = {0};
        srv_desc.Format = DXGI_FORMAT_R32_UINT;
        srv_desc.ViewDimension = D3D11_SRV_DIMENSION_BUFFER;
        srv_desc.Buffer.FirstElement = 0;
        srv_desc.Buffer.NumElements = buf->byte_size / (element_size ? element_size : 4);
        ID3D11Device_CreateShaderResourceView(dev->device, (ID3D11Resource*)buf->buffer, &srv_desc, &buf->srv);
    }
    if (buf->srv) {
        ID3D11DeviceContext_VSSetShaderResources(dev->context, slot, 1, &buf->srv);
        ID3D11DeviceContext_PSSetShaderResources(dev->context, slot, 1, &buf->srv);
    }
}

// --- Texture ---

struct DxTexture {
    ID3D11Texture2D* texture;
    ID3D11ShaderResourceView* srv;
    uint32_t width;
    uint32_t height;
    DXGI_FORMAT format;
};

DxTexture* dx_create_texture(DxDevice* dev, uint32_t width, uint32_t height, uint32_t format, const void* data) {
    if (!dev) return NULL;
    DxTexture* tex = (DxTexture*)calloc(1, sizeof(DxTexture));
    if (!tex) return NULL;
    tex->width = width;
    tex->height = height;
    tex->format = (DXGI_FORMAT)format;

    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = width;
    td.Height = height;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = tex->format;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    uint32_t bpp = (tex->format == DXGI_FORMAT_R8_UNORM) ? 1 : 4;
    D3D11_SUBRESOURCE_DATA sd = { .pSysMem = data, .SysMemPitch = width * bpp };
    HRESULT hr = ID3D11Device_CreateTexture2D(dev->device, &td, data ? &sd : NULL, &tex->texture);
    if (FAILED(hr)) { free(tex); return NULL; }

    D3D11_SHADER_RESOURCE_VIEW_DESC srv_desc = {0};
    srv_desc.Format = tex->format;
    srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    srv_desc.Texture2D.MipLevels = 1;
    ID3D11Device_CreateShaderResourceView(dev->device, (ID3D11Resource*)tex->texture, &srv_desc, &tex->srv);

    return tex;
}

void dx_destroy_texture(DxTexture* tex) {
    if (!tex) return;
    if (tex->srv) ID3D11ShaderResourceView_Release(tex->srv);
    if (tex->texture) ID3D11Texture2D_Release(tex->texture);
    free(tex);
}

void dx_update_texture_region(DxDevice* dev, DxTexture* tex, uint32_t x, uint32_t y, uint32_t w, uint32_t h, const void* data) {
    if (!dev || !tex || !data) return;
    uint32_t bpp = (tex->format == DXGI_FORMAT_R8_UNORM) ? 1 : 4;
    D3D11_BOX box = { x, y, 0, x + w, y + h, 1 };
    ID3D11DeviceContext_UpdateSubresource(dev->context, (ID3D11Resource*)tex->texture, 0, &box, data, w * bpp, 0);
}

void dx_bind_texture(DxDevice* dev, DxTexture* tex, uint32_t slot) {
    if (!dev || !tex || !tex->srv) return;
    ID3D11DeviceContext_PSSetShaderResources(dev->context, slot, 1, &tex->srv);
}

// --- Sampler ---

struct DxSampler {
    ID3D11SamplerState* state;
};

DxSampler* dx_create_sampler(DxDevice* dev, uint32_t filter, uint32_t address_mode) {
    if (!dev) return NULL;
    DxSampler* samp = (DxSampler*)calloc(1, sizeof(DxSampler));
    if (!samp) return NULL;

    D3D11_SAMPLER_DESC sd = {0};
    sd.Filter = (D3D11_FILTER)filter;
    sd.AddressU = (D3D11_TEXTURE_ADDRESS_MODE)address_mode;
    sd.AddressV = sd.AddressU;
    sd.AddressW = sd.AddressU;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    ID3D11Device_CreateSamplerState(dev->device, &sd, &samp->state);

    return samp;
}

void dx_destroy_sampler(DxSampler* samp) {
    if (!samp) return;
    if (samp->state) ID3D11SamplerState_Release(samp->state);
    free(samp);
}

void dx_bind_sampler(DxDevice* dev, DxSampler* samp, uint32_t slot) {
    if (!dev || !samp) return;
    ID3D11DeviceContext_PSSetSamplers(dev->context, slot, 1, &samp->state);
}

// --- Pipeline ---

struct DxPipeline {
    ID3D11VertexShader* vs;
    ID3D11PixelShader* ps;
    ID3D11InputLayout* input_layout;
};

DxPipeline* dx_create_pipeline(DxDevice* dev, const void* vs_bytecode, uint32_t vs_size,
                                const void* ps_bytecode, uint32_t ps_size,
                                const void* input_desc, uint32_t input_count) {
    if (!dev) return NULL;
    DxPipeline* pipe = (DxPipeline*)calloc(1, sizeof(DxPipeline));
    if (!pipe) return NULL;

    ID3D11Device_CreateVertexShader(dev->device, vs_bytecode, vs_size, NULL, &pipe->vs);
    ID3D11Device_CreatePixelShader(dev->device, ps_bytecode, ps_size, NULL, &pipe->ps);

    if (input_desc && input_count > 0) {
        ID3D11Device_CreateInputLayout(dev->device, (const D3D11_INPUT_ELEMENT_DESC*)input_desc,
            input_count, vs_bytecode, vs_size, &pipe->input_layout);
    }

    return pipe;
}

void dx_destroy_pipeline(DxPipeline* pipe) {
    if (!pipe) return;
    if (pipe->input_layout) ID3D11InputLayout_Release(pipe->input_layout);
    if (pipe->ps) ID3D11PixelShader_Release(pipe->ps);
    if (pipe->vs) ID3D11VertexShader_Release(pipe->vs);
    free(pipe);
}

void dx_bind_pipeline(DxDevice* dev, DxPipeline* pipe) {
    if (!dev || !pipe) return;
    ID3D11DeviceContext_VSSetShader(dev->context, pipe->vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(dev->context, pipe->ps, NULL, 0);
    ID3D11DeviceContext_IASetInputLayout(dev->context, pipe->input_layout); // NULL is OK for vertex-less draws
}

// --- Render Target ---

struct DxRenderTarget {
    ID3D11Texture2D* texture;
    ID3D11RenderTargetView* rtv;
    ID3D11ShaderResourceView* srv;
    uint32_t width;
    uint32_t height;
};

DxRenderTarget* dx_create_render_target(DxDevice* dev, uint32_t width, uint32_t height, uint32_t format) {
    if (!dev) return NULL;
    DxRenderTarget* rt = (DxRenderTarget*)calloc(1, sizeof(DxRenderTarget));
    if (!rt) return NULL;
    rt->width = width;
    rt->height = height;

    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = width;
    td.Height = height;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = (DXGI_FORMAT)format;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ID3D11Device_CreateTexture2D(dev->device, &td, NULL, &rt->texture);

    if (rt->texture) {
        ID3D11Device_CreateRenderTargetView(dev->device, (ID3D11Resource*)rt->texture, NULL, &rt->rtv);

        D3D11_SHADER_RESOURCE_VIEW_DESC srv_desc = {0};
        srv_desc.Format = td.Format;
        srv_desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
        srv_desc.Texture2D.MipLevels = 1;
        ID3D11Device_CreateShaderResourceView(dev->device, (ID3D11Resource*)rt->texture, &srv_desc, &rt->srv);
    }

    return rt;
}

void dx_destroy_render_target(DxRenderTarget* rt) {
    if (!rt) return;
    if (rt->srv) ID3D11ShaderResourceView_Release(rt->srv);
    if (rt->rtv) ID3D11RenderTargetView_Release(rt->rtv);
    if (rt->texture) ID3D11Texture2D_Release(rt->texture);
    free(rt);
}

void dx_bind_render_target(DxDevice* dev, DxRenderTarget* rt) {
    if (!dev || !rt) return;
    ID3D11DeviceContext_OMSetRenderTargets(dev->context, 1, &rt->rtv, NULL);
}

// --- Draw ---

void dx_draw(DxDevice* dev, uint32_t vertex_count, uint32_t start, uint32_t topology) {
    if (!dev) return;
    ID3D11DeviceContext_IASetPrimitiveTopology(dev->context, (D3D11_PRIMITIVE_TOPOLOGY)topology);
    ID3D11DeviceContext_Draw(dev->context, vertex_count, start);
}

void dx_draw_instanced(DxDevice* dev, uint32_t vertex_count, uint32_t instance_count,
                        uint32_t start_vertex, uint32_t start_instance, uint32_t topology) {
    if (!dev) return;
    ID3D11DeviceContext_IASetPrimitiveTopology(dev->context, (D3D11_PRIMITIVE_TOPOLOGY)topology);
    ID3D11DeviceContext_DrawInstanced(dev->context, vertex_count, instance_count, start_vertex, start_instance);
}

// --- Shader compilation ---

DxCompiledShader dx_compile_shader(const char* source, uint32_t source_len,
                                    const char* entry_point, const char* target) {
    DxCompiledShader result = {0};
    ID3DBlob* blob = NULL;
    ID3DBlob* errors = NULL;

    HRESULT hr = D3DCompile(source, source_len, NULL, NULL, D3D_COMPILE_STANDARD_FILE_INCLUDE,
        entry_point, target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &blob, &errors);

    if (FAILED(hr)) {
        if (errors) {
            OutputDebugStringA("HLSL compile error: ");
            OutputDebugStringA((const char*)ID3D10Blob_GetBufferPointer(errors));
            OutputDebugStringA("\n");
            ID3D10Blob_Release(errors);
        }
        return result;
    }
    if (errors) ID3D10Blob_Release(errors);

    result.size = (uint32_t)ID3D10Blob_GetBufferSize(blob);
    result.bytecode = malloc(result.size);
    if (result.bytecode) {
        memcpy(result.bytecode, ID3D10Blob_GetBufferPointer(blob), result.size);
    }
    ID3D10Blob_Release(blob);
    return result;
}

void dx_free_compiled_shader(DxCompiledShader shader) {
    free(shader.bytecode);
}

// Create pipeline with BgImage vertex input layout
DxPipeline* dx_create_bg_image_pipeline(DxDevice* dev, const void* vs_bytecode, uint32_t vs_size,
                                         const void* ps_bytecode, uint32_t ps_size) {
    if (!dev) return NULL;
    D3D11_INPUT_ELEMENT_DESC layout[] = {
        {"OPACITY", 0, DXGI_FORMAT_R32_FLOAT, 0, 0, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"INFO",    0, DXGI_FORMAT_R8_UINT,   0, 4, D3D11_INPUT_PER_INSTANCE_DATA, 1},
    };
    return dx_create_pipeline(dev, vs_bytecode, vs_size, ps_bytecode, ps_size,
                              layout, sizeof(layout) / sizeof(layout[0]));
}

// Create pipeline with Image vertex input layout
DxPipeline* dx_create_image_pipeline(DxDevice* dev, const void* vs_bytecode, uint32_t vs_size,
                                      const void* ps_bytecode, uint32_t ps_size) {
    if (!dev) return NULL;
    D3D11_INPUT_ELEMENT_DESC layout[] = {
        {"GRID_POS",    0, DXGI_FORMAT_R32G32_FLOAT,       0,  0, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"CELL_OFFSET", 0, DXGI_FORMAT_R32G32_FLOAT,       0,  8, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"SOURCE_RECT", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 16, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"DEST_SIZE",   0, DXGI_FORMAT_R32G32_FLOAT,       0, 32, D3D11_INPUT_PER_INSTANCE_DATA, 1},
    };
    return dx_create_pipeline(dev, vs_bytecode, vs_size, ps_bytecode, ps_size,
                              layout, sizeof(layout) / sizeof(layout[0]));
}

// Create pipeline with CellText vertex input layout
// Matches the VSInput struct in cell_text.hlsl and CellText in shaders.zig
DxPipeline* dx_create_cell_text_pipeline(DxDevice* dev, const void* vs_bytecode, uint32_t vs_size,
                                          const void* ps_bytecode, uint32_t ps_size) {
    if (!dev) return NULL;

    D3D11_INPUT_ELEMENT_DESC layout[] = {
        // glyph_pos: uint2, offset 0
        {"GLYPH_POS",    0, DXGI_FORMAT_R32G32_UINT,    0,  0, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        // glyph_size: uint2, offset 8
        {"GLYPH_SIZE",   0, DXGI_FORMAT_R32G32_UINT,    0,  8, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        // bearings: int2 (i16x2), offset 16
        {"BEARINGS",     0, DXGI_FORMAT_R16G16_SINT,    0, 16, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        // grid_pos: uint2 (u16x2), offset 20
        {"GRID_POS",     0, DXGI_FORMAT_R16G16_UINT,    0, 20, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        // color: uint4 (u8x4), offset 24
        {"COLOR",        0, DXGI_FORMAT_R8G8B8A8_UINT,  0, 24, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        // atlas: uint (u8), offset 28
        {"ATLAS",        0, DXGI_FORMAT_R8_UINT,         0, 28, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        // glyph_bools: uint (u8), offset 29
        {"GLYPH_BOOLS",  0, DXGI_FORMAT_R8_UINT,         0, 29, D3D11_INPUT_PER_INSTANCE_DATA, 1},
    };

    return dx_create_pipeline(dev, vs_bytecode, vs_size, ps_bytecode, ps_size,
                              layout, sizeof(layout) / sizeof(layout[0]));
}

// --- Window resize notification ---

void dx_set_window_size(uint32_t width, uint32_t height) {
    g_window_width = width;
    g_window_height = height;
}

void dx_get_window_size(uint32_t* width, uint32_t* height) {
    *width = g_window_width;
    *height = g_window_height;
}


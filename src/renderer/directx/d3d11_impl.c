// D3D11 implementation wrapper
// Provides a flat C API over the COM-based D3D11 interfaces for Zig consumption.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d11.h>
#include <dxgi.h>
#include <dxgi1_2.h>
#include <dxgi1_3.h>
// dcomp.h is C++-only; declare the minimal DirectComposition interfaces in C.
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dcomp.lib")

DEFINE_GUID(IID_IDCompositionDevice,  0xC37EA93A, 0xE7AA, 0x450D, 0xB1, 0x6F, 0x97, 0x46, 0xCB, 0x04, 0x07, 0xF3);
DEFINE_GUID(IID_IDXGIFactoryMedia_local, 0x41e7d1f2, 0xa591, 0x4f7b, 0xa2, 0xe5, 0xfa, 0x9c, 0x84, 0x3e, 0x1c, 0x12);

// Minimal IDCompositionVisual vtable (only SetContent + Release needed).
// Each C++ overload occupies its own vtable slot.
typedef struct IDCompositionVisual IDCompositionVisual;
typedef struct IDCompositionVisualVtbl {
    // IUnknown (slots 0-2)
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDCompositionVisual*, REFIID, void**);
    ULONG   (STDMETHODCALLTYPE *AddRef)(IDCompositionVisual*);
    ULONG   (STDMETHODCALLTYPE *Release)(IDCompositionVisual*);
    // SetOffsetX: 2 overloads (animation, float) — slots 3-4
    void* _SetOffsetX_anim;
    void* _SetOffsetX_float;
    // SetOffsetY: 2 overloads — slots 5-6
    void* _SetOffsetY_anim;
    void* _SetOffsetY_float;
    // SetTransform: 2 overloads — slots 7-8
    void* _SetTransform_obj;
    void* _SetTransform_matrix;
    // SetTransformParent — slot 9
    void* _SetTransformParent;
    // SetEffect — slot 10
    void* _SetEffect;
    // SetBitmapInterpolationMode — slot 11
    void* _SetBitmapInterpolationMode;
    // SetBorderMode — slot 12
    void* _SetBorderMode;
    // SetClip: 2 overloads — slots 13-14
    void* _SetClip_obj;
    void* _SetClip_rect;
    // SetContent — slot 15
    HRESULT (STDMETHODCALLTYPE *SetContent)(IDCompositionVisual*, IUnknown*);
} IDCompositionVisualVtbl;
struct IDCompositionVisual { IDCompositionVisualVtbl* lpVtbl; };

// Minimal IDCompositionTarget vtable (only SetRoot + Release needed)
typedef struct IDCompositionTarget IDCompositionTarget;
typedef struct IDCompositionTargetVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDCompositionTarget*, REFIID, void**);
    ULONG   (STDMETHODCALLTYPE *AddRef)(IDCompositionTarget*);
    ULONG   (STDMETHODCALLTYPE *Release)(IDCompositionTarget*);
    HRESULT (STDMETHODCALLTYPE *SetRoot)(IDCompositionTarget*, IDCompositionVisual*);
} IDCompositionTargetVtbl;
struct IDCompositionTarget { IDCompositionTargetVtbl* lpVtbl; };

// Minimal IDCompositionDevice vtable
typedef struct IDCompositionDevice IDCompositionDevice;
typedef struct IDCompositionDeviceVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDCompositionDevice*, REFIID, void**);
    ULONG   (STDMETHODCALLTYPE *AddRef)(IDCompositionDevice*);
    ULONG   (STDMETHODCALLTYPE *Release)(IDCompositionDevice*);
    HRESULT (STDMETHODCALLTYPE *Commit)(IDCompositionDevice*);
    HRESULT (STDMETHODCALLTYPE *WaitForCommitCompletion)(IDCompositionDevice*);
    HRESULT (STDMETHODCALLTYPE *GetFrameStatistics)(IDCompositionDevice*, void*);
    HRESULT (STDMETHODCALLTYPE *CreateTargetForHwnd)(IDCompositionDevice*, HWND, BOOL, IDCompositionTarget**);
    HRESULT (STDMETHODCALLTYPE *CreateVisual)(IDCompositionDevice*, IDCompositionVisual**);
} IDCompositionDeviceVtbl;
struct IDCompositionDevice { IDCompositionDeviceVtbl* lpVtbl; };

// DCompositionCreateDevice is a flat C export from dcomp.dll
HRESULT WINAPI DCompositionCreateDevice(IDXGIDevice*, REFIID, void**);

#define IDCompositionDevice_CreateTargetForHwnd(p,a,b,c) (p)->lpVtbl->CreateTargetForHwnd(p,a,b,c)
#define IDCompositionDevice_CreateVisual(p,a)            (p)->lpVtbl->CreateVisual(p,a)
#define IDCompositionDevice_Commit(p)                    (p)->lpVtbl->Commit(p)
#define IDCompositionDevice_Release(p)                   (p)->lpVtbl->Release(p)
#define IDCompositionTarget_SetRoot(p,a)                 (p)->lpVtbl->SetRoot(p,a)
#define IDCompositionTarget_Release(p)                   (p)->lpVtbl->Release(p)
#define IDCompositionVisual_SetContent(p,a)              (p)->lpVtbl->SetContent(p,a)
#define IDCompositionVisual_Release(p)                   (p)->lpVtbl->Release(p)

#include "d3d11_impl.h"

// --- Device ---

struct DxDevice {
    ID3D11Device* device;
    ID3D11DeviceContext* context;
    IDXGISwapChain* swap_chain;
    ID3D11RenderTargetView* backbuffer_rtv;
    ID3D11BlendState* blend_on;
    ID3D11BlendState* blend_off;
    ID3D11RasterizerState* rasterizer_state;
    ID3D11SamplerState* default_sampler;
    IDCompositionDevice* dcomp_device;
    IDCompositionTarget* dcomp_target;
    IDCompositionVisual* dcomp_visual;
    D3D_FEATURE_LEVEL feature_level;
    HWND hwnd;
    uint32_t bb_width;
    uint32_t bb_height;
    // Per-device window size (set by main thread via dx_set_window_size,
    // read by renderer thread). Volatile for cross-thread visibility.
    volatile uint32_t window_width;
    volatile uint32_t window_height;
    // Frame latency waitable object handle (NULL if not used).
    // Owned by the swap chain — do NOT CloseHandle on this.
    HANDLE frame_latency_waitable;
    // Guard against double-waiting on the auto-reset event.
    // Set true after Present, cleared after wait.
    volatile bool wait_for_presentation;
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

    // Create swap chain for composition (not bound to HWND directly).
    // This allows DirectComposition to control visibility without crashing
    // the D3D driver when a surface is hidden during tab switching.
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
    scd.Scaling = DXGI_SCALING_STRETCH;
    scd.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

    IDXGISwapChain1* swap_chain1 = NULL;
    hr = IDXGIFactory2_CreateSwapChainForComposition(factory, (IUnknown*)dev->device, &scd, NULL, &swap_chain1);

    IDXGIFactory2_Release(factory);
    IDXGIAdapter_Release(adapter);

    if (FAILED(hr) || !swap_chain1) {
        OutputDebugStringA("D3D11: CreateSwapChainForComposition FAILED\n");
        IDXGIDevice_Release(dxgi_device);
        ID3D11DeviceContext_Release(dev->context);
        ID3D11Device_Release(dev->device);
        free(dev);
        return NULL;
    }

    // Set up DirectComposition: visual tree routes the swap chain to the HWND.
    // Visibility is controlled by attaching/detaching the visual root.
    hr = DCompositionCreateDevice((IDXGIDevice*)dxgi_device, &IID_IDCompositionDevice, (void**)&dev->dcomp_device);
    IDXGIDevice_Release(dxgi_device);
    if (FAILED(hr)) {
        OutputDebugStringA("D3D11: DCompositionCreateDevice FAILED\n");
        IDXGISwapChain1_Release(swap_chain1);
        ID3D11DeviceContext_Release(dev->context);
        ID3D11Device_Release(dev->device);
        free(dev);
        return NULL;
    }

    IDCompositionDevice_CreateTargetForHwnd(dev->dcomp_device, dev->hwnd, TRUE, &dev->dcomp_target);
    IDCompositionDevice_CreateVisual(dev->dcomp_device, &dev->dcomp_visual);
    IDCompositionVisual_SetContent(dev->dcomp_visual, (IUnknown*)swap_chain1);
    IDCompositionTarget_SetRoot(dev->dcomp_target, dev->dcomp_visual);
    IDCompositionDevice_Commit(dev->dcomp_device);

    // Get IDXGISwapChain from IDXGISwapChain1
    IDXGISwapChain1_QueryInterface(swap_chain1, &IID_IDXGISwapChain, (void**)&dev->swap_chain);
    IDXGISwapChain1_Release(swap_chain1);
#ifndef NDEBUG
    OutputDebugStringA("D3D11: Device created successfully\n");
#endif

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

    // Create default sampler immediately so it's ready for the first draw
    {
        D3D11_SAMPLER_DESC sd = {0};
        sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.MaxLOD = D3D11_FLOAT32_MAX;
        ID3D11Device_CreateSamplerState(dev->device, &sd, &dev->default_sampler);
        if (dev->default_sampler) {
            ID3D11DeviceContext_PSSetSamplers(dev->context, 0, 1, &dev->default_sampler);
        }
    }

    return dev;
}

static int present_count = 0;

DxDevice* dx_create_from_swap_chain(void* d3d_device, void* swap_chain_ptr, uint32_t width, uint32_t height) {
    if (!d3d_device || !swap_chain_ptr) return NULL;

    DxDevice* dev = (DxDevice*)calloc(1, sizeof(DxDevice));
    if (!dev) return NULL;

    // Borrow device and swap chain — AddRef since DxDevice will Release on destroy
    dev->device = (ID3D11Device*)d3d_device;
    ID3D11Device_AddRef(dev->device);
    ID3D11Device_GetImmediateContext(dev->device, &dev->context);

    IDXGISwapChain1* sc1 = (IDXGISwapChain1*)swap_chain_ptr;
    IDXGISwapChain1_QueryInterface(sc1, &IID_IDXGISwapChain, (void**)&dev->swap_chain);

    // Try to get IDXGISwapChain2 for frame latency waitable.
    // Only works if the swap chain was created with
    // DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT.
    {
        IDXGISwapChain2* sc2 = NULL;
        if (SUCCEEDED(IDXGISwapChain1_QueryInterface(sc1, &IID_IDXGISwapChain2, (void**)&sc2))) {
            // Don't call SetMaximumFrameLatency — default is 1 (minimum latency).
            // MS sample explicitly comments out this call as redundant.
            dev->frame_latency_waitable = IDXGISwapChain2_GetFrameLatencyWaitableObject(sc2);
            // Initial state is signaled — first wait passes through immediately.
            dev->wait_for_presentation = true;
            IDXGISwapChain2_Release(sc2);
#ifndef NDEBUG
            if (dev->frame_latency_waitable) {
                OutputDebugStringA("D3D11: Frame latency waitable enabled\n");
            }
#endif
        }
    }

    dev->feature_level = ID3D11Device_GetFeatureLevel(dev->device);
    // No DirectComposition — SwapChainPanel manages composition

#ifndef NDEBUG
    {
        DXGI_SWAP_CHAIN_DESC desc = {0};
        IDXGISwapChain_GetDesc(dev->swap_chain, &desc);
        char buf[256];
        sprintf(buf, "D3D11: External swap chain: %ux%u fmt=%u buffers=%u swap=%u hwnd=%p\n",
            desc.BufferDesc.Width, desc.BufferDesc.Height,
            desc.BufferDesc.Format, desc.BufferCount, desc.SwapEffect,
            (void*)desc.OutputWindow);
        OutputDebugStringA(buf);
    }
#endif
    present_count = 0;

    dx_create_backbuffer_rtv(dev);
    dev->bb_width = width;
    dev->bb_height = height;

#ifndef NDEBUG
    {
        char buf[128];
        sprintf(buf, "D3D11: Backbuffer RTV: %p, context: %p\n",
            (void*)dev->backbuffer_rtv, (void*)dev->context);
        OutputDebugStringA(buf);
    }
#endif

    // Blend states
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

    // Rasterizer
    D3D11_RASTERIZER_DESC rd = {0};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.FrontCounterClockwise = FALSE;
    rd.DepthClipEnable = TRUE;
    ID3D11Device_CreateRasterizerState(dev->device, &rd, &dev->rasterizer_state);
    if (dev->rasterizer_state) {
        ID3D11DeviceContext_RSSetState(dev->context, dev->rasterizer_state);
    }

    // Default sampler
    {
        D3D11_SAMPLER_DESC sd = {0};
        sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.MaxLOD = D3D11_FLOAT32_MAX;
        ID3D11Device_CreateSamplerState(dev->device, &sd, &dev->default_sampler);
        if (dev->default_sampler) {
            ID3D11DeviceContext_PSSetSamplers(dev->context, 0, 1, &dev->default_sampler);
        }
    }

    return dev;
}

// Create device + swap chain owned entirely by the calling thread.
// This matches Windows Terminal AtlasEngine: SINGLETHREADED device created
// inside the renderer thread, paired with a swap chain bound to a DComp
// surface handle. The surface handle was created by the host C++ code and
// already attached to the SwapChainPanel via SetSwapChainHandle.
DxDevice* dx_create_for_composition_surface(void* surface_handle_ptr, uint32_t width, uint32_t height) {
    if (!surface_handle_ptr) return NULL;
    HANDLE surface_handle = (HANDLE)surface_handle_ptr;

    DxDevice* dev = (DxDevice*)calloc(1, sizeof(DxDevice));
    if (!dev) return NULL;

    // Pick the default adapter via DXGI factory.
    IDXGIFactory2* factory = NULL;
    HRESULT hr = CreateDXGIFactory2(0, &IID_IDXGIFactory2, (void**)&factory);
    if (FAILED(hr) || !factory) {
        OutputDebugStringA("D3D11: CreateDXGIFactory2 FAILED\n");
        free(dev);
        return NULL;
    }
    IDXGIAdapter* adapter = NULL;
    IDXGIFactory2_EnumAdapters(factory, 0, &adapter);

    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT
               | D3D11_CREATE_DEVICE_SINGLETHREADED
               | D3D11_CREATE_DEVICE_PREVENT_INTERNAL_THREADING_OPTIMIZATIONS;
#ifndef NDEBUG
    flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
    D3D_FEATURE_LEVEL feature_levels[] = { D3D_FEATURE_LEVEL_11_0 };
    hr = D3D11CreateDevice(
        adapter, adapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE,
        NULL, flags, feature_levels, 1, D3D11_SDK_VERSION,
        &dev->device, &dev->feature_level, &dev->context);
    if (FAILED(hr) || !dev->device) {
        OutputDebugStringA("D3D11: D3D11CreateDevice FAILED (composition surface)\n");
        if (adapter) IDXGIAdapter_Release(adapter);
        IDXGIFactory2_Release(factory);
        free(dev);
        return NULL;
    }

    // Build the swap chain matching WT AtlasEngine exactly.
    DXGI_SWAP_CHAIN_DESC1 scd = {0};
    scd.Width = width;
    scd.Height = height;
    scd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    scd.SampleDesc.Count = 1;
    scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.BufferCount = 3;
    scd.Scaling = DXGI_SCALING_STRETCH;  // SwapChainPanel requires STRETCH
    scd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    scd.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    scd.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

    // CreateSwapChainForCompositionSurfaceHandle lives on IDXGIFactoryMedia.
    // We declare a minimal vtable in C; the IID is defined at file scope.
    typedef struct IDXGIFactoryMedia IDXGIFactoryMedia;
    typedef struct IDXGIFactoryMediaVtbl {
        HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDXGIFactoryMedia*, REFIID, void**);
        ULONG   (STDMETHODCALLTYPE *AddRef)(IDXGIFactoryMedia*);
        ULONG   (STDMETHODCALLTYPE *Release)(IDXGIFactoryMedia*);
        // SetPrivateData/GetPrivateData/SetPrivateDataInterface/GetParent — IDXGIObject
        void* _SetPrivateData;
        void* _SetPrivateDataInterface;
        void* _GetPrivateData;
        void* _GetParent;
        // CreateSwapChainForCompositionSurfaceHandle (slot 8)
        HRESULT (STDMETHODCALLTYPE *CreateSwapChainForCompositionSurfaceHandle)(
            IDXGIFactoryMedia*, IUnknown*, HANDLE,
            const DXGI_SWAP_CHAIN_DESC1*, void*, IDXGISwapChain1**);
    } IDXGIFactoryMediaVtbl;
    struct IDXGIFactoryMedia { IDXGIFactoryMediaVtbl* lpVtbl; };

    IDXGIFactoryMedia* factory_media = NULL;
    hr = IDXGIFactory2_QueryInterface(factory, &IID_IDXGIFactoryMedia_local, (void**)&factory_media);
    IDXGIFactory2_Release(factory);
    if (adapter) IDXGIAdapter_Release(adapter);
    if (FAILED(hr) || !factory_media) {
        OutputDebugStringA("D3D11: QueryInterface IDXGIFactoryMedia FAILED\n");
        ID3D11DeviceContext_Release(dev->context);
        ID3D11Device_Release(dev->device);
        free(dev);
        return NULL;
    }

    IDXGISwapChain1* swap_chain1 = NULL;
    hr = factory_media->lpVtbl->CreateSwapChainForCompositionSurfaceHandle(
        factory_media, (IUnknown*)dev->device, surface_handle, &scd, NULL, &swap_chain1);
    factory_media->lpVtbl->Release(factory_media);
    if (FAILED(hr) || !swap_chain1) {
        char buf[128];
        sprintf(buf, "D3D11: CreateSwapChainForCompositionSurfaceHandle FAILED hr=0x%08X\n", (unsigned)hr);
        OutputDebugStringA(buf);
        ID3D11DeviceContext_Release(dev->context);
        ID3D11Device_Release(dev->device);
        free(dev);
        return NULL;
    }

    // Get the waitable handle (matches WT) and explicitly set max latency to 1.
    {
        IDXGISwapChain2* sc2 = NULL;
        if (SUCCEEDED(IDXGISwapChain1_QueryInterface(swap_chain1, &IID_IDXGISwapChain2, (void**)&sc2))) {
            IDXGISwapChain2_SetMaximumFrameLatency(sc2, 1);
            dev->frame_latency_waitable = IDXGISwapChain2_GetFrameLatencyWaitableObject(sc2);
            dev->wait_for_presentation = true;
            IDXGISwapChain2_Release(sc2);
        }
    }

    IDXGISwapChain1_QueryInterface(swap_chain1, &IID_IDXGISwapChain, (void**)&dev->swap_chain);
    IDXGISwapChain1_Release(swap_chain1);

    dx_create_backbuffer_rtv(dev);
    dev->bb_width = width;
    dev->bb_height = height;

    // Standard state objects (same as other paths).
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

    D3D11_RASTERIZER_DESC rd = {0};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.DepthClipEnable = TRUE;
    ID3D11Device_CreateRasterizerState(dev->device, &rd, &dev->rasterizer_state);
    if (dev->rasterizer_state) {
        ID3D11DeviceContext_RSSetState(dev->context, dev->rasterizer_state);
    }

    D3D11_SAMPLER_DESC sd = {0};
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    ID3D11Device_CreateSamplerState(dev->device, &sd, &dev->default_sampler);
    if (dev->default_sampler) {
        ID3D11DeviceContext_PSSetSamplers(dev->context, 0, 1, &dev->default_sampler);
    }

    OutputDebugStringA("D3D11: Device + swap chain created for composition surface\n");
    return dev;
}

void dx_destroy(DxDevice* dev) {
    if (!dev) return;
    // ClearState + Flush trigger deferred destruction of DXGI flip-model
    // swap chains. Without this, creating a new swap chain on the same
    // HWND/IWindow/composition surface fails with DXGI ERROR #297.
    // We then block on a query event so the GPU actually finishes pending
    // work before we Release the swap chain — Flush only schedules.
    if (dev->context && dev->device) {
        ID3D11DeviceContext_ClearState(dev->context);
        ID3D11DeviceContext_Flush(dev->context);

        ID3D11Query* query = NULL;
        D3D11_QUERY_DESC qd = { D3D11_QUERY_EVENT, 0 };
        if (SUCCEEDED(ID3D11Device_CreateQuery(dev->device, &qd, &query)) && query) {
            ID3D11DeviceContext_End(dev->context, (ID3D11Asynchronous*)query);
            BOOL done = FALSE;
            for (int i = 0; i < 1000 && !done; i++) {
                if (ID3D11DeviceContext_GetData(dev->context, (ID3D11Asynchronous*)query,
                                                 &done, sizeof(done), 0) == S_OK && done) {
                    break;
                }
                Sleep(1);
            }
            ID3D11Query_Release(query);
        }
    }
    if (dev->dcomp_visual) IDCompositionVisual_Release(dev->dcomp_visual);
    if (dev->dcomp_target) IDCompositionTarget_Release(dev->dcomp_target);
    if (dev->dcomp_device) IDCompositionDevice_Release(dev->dcomp_device);
    if (dev->default_sampler) ID3D11SamplerState_Release(dev->default_sampler);
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

    __try {
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

        // Preserve FRAME_LATENCY_WAITABLE_OBJECT flag if it was set —
        // ResizeBuffers strips flags unless we pass them explicitly.
        UINT flags = dev->frame_latency_waitable ? DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT : 0;
        HRESULT hr = IDXGISwapChain_ResizeBuffers(dev->swap_chain, 0, width, height, DXGI_FORMAT_UNKNOWN, flags);
        if (SUCCEEDED(hr)) {
            dx_create_backbuffer_rtv(dev);
            dev->bb_width = width;
            dev->bb_height = height;
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("D3D11: CRASH in Resize!\n");
    }
}

void dx_present(DxDevice* dev, bool vsync) {
    if (!dev || !dev->swap_chain) return;

    present_count++;

#ifndef NDEBUG
    if (present_count <= 5) {
        DXGI_SWAP_CHAIN_DESC desc = {0};
        IDXGISwapChain_GetDesc(dev->swap_chain, &desc);
        char buf[256];
        sprintf(buf, "D3D11: Present #%d: %ux%u fmt=%u buffers=%u swap=%u flags=0x%x rtv=%p ctx=%p\n",
            present_count, desc.BufferDesc.Width, desc.BufferDesc.Height,
            desc.BufferDesc.Format, desc.BufferCount, desc.SwapEffect,
            desc.Flags, (void*)dev->backbuffer_rtv, (void*)dev->context);
        OutputDebugStringA(buf);
    }
#endif

    __try {
        HRESULT hr = IDXGISwapChain_Present(dev->swap_chain, vsync ? 1 : 0, 0);
        if (SUCCEEDED(hr)) {
            // Mark that the waitable will be signaled by this Present.
            dev->wait_for_presentation = true;
        }
        if (FAILED(hr)) {
#ifndef NDEBUG
            char buf[128];
            sprintf(buf, "D3D11: Present #%d failed: hr=0x%08X\n", present_count, (unsigned)hr);
            OutputDebugStringA(buf);
#endif
            if (hr == DXGI_ERROR_DEVICE_REMOVED) {
                HRESULT reason = ID3D11Device_GetDeviceRemovedReason(dev->device);
                char buf2[128];
                sprintf(buf2, "D3D11: Device removed reason: 0x%08X\n", (unsigned)reason);
                OutputDebugStringA(buf2);
            }
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        char buf[128];
        sprintf(buf, "D3D11: CRASH in Present #%d! Exception code: 0x%08lX\n",
            present_count, GetExceptionCode());
        OutputDebugStringA(buf);
    }
}

void* dx_get_swap_chain(DxDevice* dev) {
    if (!dev || !dev->swap_chain) return NULL;
    // Return IDXGISwapChain1* via QueryInterface
    IDXGISwapChain1* sc1 = NULL;
    HRESULT hr = IDXGISwapChain_QueryInterface(dev->swap_chain, &IID_IDXGISwapChain1, (void**)&sc1);
    if (FAILED(hr)) return NULL;
    // Release the extra ref — caller borrows, does NOT own
    IDXGISwapChain1_Release(sc1);
    return sc1;
}

void dx_clear(DxDevice* dev, float r, float g, float b, float a) {
    if (!dev || !dev->backbuffer_rtv) return;
    float color[4] = { r, g, b, a };
    __try {
        ID3D11DeviceContext_ClearRenderTargetView(dev->context, dev->backbuffer_rtv, color);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("D3D11: CRASH in Clear!\n");
    }
}

void dx_set_viewport(DxDevice* dev, uint32_t width, uint32_t height) {
    if (!dev) return;
    D3D11_VIEWPORT vp = { 0, 0, (float)width, (float)height, 0.0f, 1.0f };
    __try {
        ID3D11DeviceContext_RSSetViewports(dev->context, 1, &vp);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("D3D11: CRASH in SetViewport!\n");
    }
}

void dx_bind_backbuffer(DxDevice* dev) {
    if (!dev) return;
    __try {
        ID3D11DeviceContext_OMSetRenderTargets(dev->context, 1, &dev->backbuffer_rtv, NULL);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("D3D11: CRASH in BindBackbuffer!\n");
    }
}

void dx_set_blend_enabled(DxDevice* dev, bool enabled) {
    if (!dev) return;
    float blend_factor[4] = { 0, 0, 0, 0 };
    __try {
        ID3D11DeviceContext_OMSetBlendState(dev->context, enabled ? dev->blend_on : dev->blend_off, blend_factor, 0xFFFFFFFF);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("D3D11: CRASH in SetBlend!\n");
    }
}

void dx_clear_shader_resources(DxDevice* dev) {
    if (!dev) return;
    __try {
        ID3D11ShaderResourceView* nullSRVs[8] = {0};
        ID3D11DeviceContext_VSSetShaderResources(dev->context, 0, 8, nullSRVs);
        ID3D11DeviceContext_PSSetShaderResources(dev->context, 0, 8, nullSRVs);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("D3D11: CRASH in ClearShaderResources!\n");
    }
}

void dx_ensure_default_sampler(DxDevice* dev) {
    if (!dev) return;
    // Create once per device, but always re-bind — pipeline state changes can unbind it.
    if (!dev->default_sampler) {
        D3D11_SAMPLER_DESC sd = {0};
        sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sd.MaxLOD = D3D11_FLOAT32_MAX;
        ID3D11Device_CreateSamplerState(dev->device, &sd, &dev->default_sampler);
    }
    if (dev->default_sampler) {
        ID3D11DeviceContext_PSSetSamplers(dev->context, 0, 1, &dev->default_sampler);
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
    __try {
        D3D11_MAPPED_SUBRESOURCE mapped;
        HRESULT hr = ID3D11DeviceContext_Map(dev->context, (ID3D11Resource*)buf->buffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
        if (SUCCEEDED(hr)) {
            memcpy(mapped.pData, data, byte_size < buf->byte_size ? byte_size : buf->byte_size);
            ID3D11DeviceContext_Unmap(dev->context, (ID3D11Resource*)buf->buffer, 0);
        }
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("D3D11: CRASH in UpdateBuffer! Caught by SEH.\n");
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
    __try {
        ID3D11DeviceContext_UpdateSubresource(dev->context, (ID3D11Resource*)tex->texture, 0, &box, data, w * bpp, 0);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        char buf[256];
        sprintf(buf, "D3D11: CRASH in UpdateSubresource! tex=%p region=(%u,%u,%u,%u) bpp=%u data=%p\n",
            (void*)tex->texture, x, y, w, h, bpp, data);
        OutputDebugStringA(buf);
    }
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
    // Re-bind default sampler — shader switch can invalidate sampler state
    if (dev->default_sampler) {
        ID3D11DeviceContext_PSSetSamplers(dev->context, 0, 1, &dev->default_sampler);
    }
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
    __try {
        ID3D11DeviceContext_IASetPrimitiveTopology(dev->context, (D3D11_PRIMITIVE_TOPOLOGY)topology);
        ID3D11DeviceContext_Draw(dev->context, vertex_count, start);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("D3D11: CRASH in Draw! Caught by SEH.\n");
    }
}

void dx_draw_instanced(DxDevice* dev, uint32_t vertex_count, uint32_t instance_count,
                        uint32_t start_vertex, uint32_t start_instance, uint32_t topology) {
    if (!dev) return;
    __try {
        ID3D11DeviceContext_IASetPrimitiveTopology(dev->context, (D3D11_PRIMITIVE_TOPOLOGY)topology);
        ID3D11DeviceContext_DrawInstanced(dev->context, vertex_count, instance_count, start_vertex, start_instance);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        OutputDebugStringA("D3D11: CRASH in DrawInstanced! Caught by SEH.\n");
    }
}

// Shader compilation removed — using precompiled CSO blobs instead.

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

void dx_set_window_size(DxDevice* dev, uint32_t width, uint32_t height) {
    if (dev) {
        dev->window_width = width;
        dev->window_height = height;
    }
}

void dx_get_window_size(DxDevice* dev, uint32_t* width, uint32_t* height) {
    if (dev) {
        *width = dev->window_width;
        *height = dev->window_height;
    } else {
        *width = 0;
        *height = 0;
    }
}

// --- DirectComposition visibility ---

void dx_set_visible(DxDevice* dev, bool visible) {
    if (!dev || !dev->dcomp_target) return;
    IDCompositionTarget_SetRoot(dev->dcomp_target, visible ? dev->dcomp_visual : NULL);
    IDCompositionDevice_Commit(dev->dcomp_device);
}

void dx_wait_frame_latency(DxDevice* dev) {
    if (!dev || !dev->frame_latency_waitable) return;
    // Auto-reset event: only wait if a Present has signaled it.
    // Otherwise we'd block until timeout, causing visible stalls.
    if (!dev->wait_for_presentation) return;
    WaitForSingleObjectEx(dev->frame_latency_waitable, 100, TRUE);
    dev->wait_for_presentation = false;
}


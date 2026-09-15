const std = @import("std");
const DirectX = @import("../DirectX.zig");
const rendererpkg = @import("../../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(DirectX);
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Self = @This();

const log = std.log.scoped(.directx);

renderer: *Renderer,
target: *Target,

pub fn begin(renderer: *Renderer, target: *Target) !Self {
    return .{
        .renderer = renderer,
        .target = target,
    };
}

pub fn renderPass(self: *const Self, attachments: []const RenderPass.Options.Attachment) RenderPass {
    // Pass device handle from the renderer's API. The device lives in
    // a heap-allocated `Presentation` struct on the API, populated by
    // threadEnter on the renderer thread.
    return RenderPass.begin(self.renderer.api.presentation.device, .{ .attachments = attachments });
}

pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;
    // Hand the completed target to the API. For DirectX this is the
    // "a full frame really was drawn" signal that arms the Present in
    // drawFrameEnd — without it, drawFrameEnd would present the
    // cleared-black backbuffer on paths that skip drawing (no-redraw,
    // zero-size, synchronized-output). Mirrors opengl/Frame.zig.
    self.renderer.api.present(self.target.*) catch |err| {
        log.err("failed to present render target err={}", .{err});
    };
    // Report frame health and release the swap chain semaphore.
    // Without this, the semaphore exhausts after swap_chain_count frames
    // and nextFrame() blocks forever.
    self.renderer.frameCompleted(.healthy);
}

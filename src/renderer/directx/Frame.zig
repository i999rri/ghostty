const std = @import("std");
const DirectX = @import("../DirectX.zig");
const rendererpkg = @import("../../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(DirectX);
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Self = @This();

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
    // Report frame health and release the swap chain semaphore.
    // Without this, the semaphore exhausts after swap_chain_count frames
    // and nextFrame() blocks forever.
    self.renderer.frameCompleted(.healthy);
}

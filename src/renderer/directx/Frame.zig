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
    // Pass device handle from the renderer's API
    return RenderPass.begin(self.renderer.api.device, .{ .attachments = attachments });
}

pub fn complete(self: *const Self, sync: bool) void {
    _ = self;
    if (sync) {
        // Flush the D3D11 command queue to ensure all commands are submitted.
        // D3D11 doesn't have a direct equivalent of glFinish(), but
        // the present call in drawFrameEnd handles synchronization.
    }
}

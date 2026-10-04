//! Represents the renderer thread logic. The renderer thread is able to
//! be woken up to render.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const rendererpkg = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const terminalpkg = @import("../terminal/main.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;
const App = @import("../App.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.renderer_thread);

const CURSOR_BLINK_INTERVAL = 600;

/// Native render loop safety net (ms): force a full update+draw this
/// often even with no wakeup/mailbox activity, so a dropped notify
/// degrades to a briefly-stale frame instead of a permanently-stale one.
const NATIVE_FORCED_REDRAW_INTERVAL = 1000;

/// Whether to use a native render loop instead of xev's event loop.
/// DirectX on Windows requires this because xev's IOCP is incompatible with D3D11.
const use_native_loop = blk: {
    const RendererType = rendererpkg.Renderer;
    break :blk @hasDecl(RendererType, "API") and
        @hasDecl(RendererType.API, "native_render_loop") and
        RendererType.API.native_render_loop;
};

/// Whether calls to `drawFrame` must be done from the app thread.
///
/// The type used for sending messages to the IO thread. For now this is
/// hardcoded with a capacity. We can make this a comptime parameter in
/// the future if we want it configurable.
pub const Mailbox = BlockingQueue(rendererpkg.Message, 64);

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the application. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},

/// This can be used to stop the renderer on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// The timer used for animations (custom shaders, Kitty graphics).
/// Normal rendering is driven by wakeup messages instead.
render_h: xev.Timer,
render_c: xev.Completion = .{},
render_c_cancel: xev.Completion = .{},

/// The kind of work the currently scheduled animation wake needs,
/// stored when the timer is armed.
animation_wake: rendererpkg.Renderer.AnimationWake.Kind = .draw,

/// This async is used to force a draw immediately. This does not
/// coalesce like the wakeup does.
draw_now: xev.Async,
draw_now_c: xev.Completion = .{},

/// The timer used for cursor blinking
cursor_h: xev.Timer,
cursor_c: xev.Completion = .{},
cursor_c_cancel: xev.Completion = .{},

/// Incremental scrollback compression scheduling.
compression: Compression = undefined,

/// The surface we're rendering to.
surface: *apprt.Surface,

/// The underlying renderer implementation.
renderer: *rendererpkg.Renderer,

/// Pointer to the shared state that is used to generate the final render.
state: *rendererpkg.State,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// Mailbox to send messages to the app thread
app_mailbox: App.Mailbox,

/// Configuration we need derived from the main config.
config: DerivedConfig,

flags: packed struct {
    /// This is true when a blinking cursor should be visible and false
    /// when it should not be visible. This is toggled on a timer by the
    /// thread automatically.
    cursor_blink_visible: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,

    /// This is true when the view is visible. This is used to determine
    /// if we should be rendering or not.
    visible: bool = true,

    /// This is true when the view is focused. This defaults to true
    /// and it is up to the apprt to set the correct value.
    focused: bool = true,

    /// Set by drainMailbox on reset_cursor_blink; consumed by native render loop
    cursor_blink_reset: bool = false,

    /// Native render loop only. Set by wakeupCallback / drawNowCallback
    /// when their asyncs fire through the loop.run(.no_wait) poll;
    /// consumed by nativeRenderCycle. Both are written and read on the
    /// renderer thread only (xev dispatch happens inside the poll), so
    /// no atomics are needed.
    render_requested: bool = false,
    draw_now_requested: bool = false,
} = .{},

/// Stop flag for native render loop. Only exists when use_native_loop is true.
stop_requested: if (use_native_loop) std.atomic.Value(bool) else void =
    if (use_native_loop) .{ .raw = false } else {},

pub const DerivedConfig = struct {
    scrollback_compression: bool,

    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .scrollback_compression = config.@"scrollback-compression",
        };
    }
};

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
    config: *const configpkg.Config,
    surface: *apprt.Surface,
    renderer_impl: *rendererpkg.Renderer,
    state: *rendererpkg.State,
    app_mailbox: App.Mailbox,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to "wake up" the renderer and force a render.
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // The primary timer for rendering.
    var render_h = try xev.Timer.init();
    errdefer render_h.deinit();

    // Draw now async, see comments.
    var draw_now = try xev.Async.init();
    errdefer draw_now.deinit();

    // Setup a timer for blinking the cursor
    var cursor_timer = try xev.Timer.init();
    errdefer cursor_timer.deinit();

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    var result: Thread = .{
        .alloc = alloc,
        .config = .init(config),
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .render_h = render_h,
        .draw_now = draw_now,
        .cursor_h = cursor_timer,
        .surface = surface,
        .renderer = renderer_impl,
        .state = state,
        .mailbox = mailbox,
        .app_mailbox = app_mailbox,
    };

    // Only enable compression if we have it enabled... save some
    // minor resources.
    if (comptime terminalpkg.compression_enabled) {
        result.compression = try .init();
    }

    return result;
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.stop.deinit();
    self.wakeup.deinit();
    self.render_h.deinit();
    self.draw_now.deinit();
    self.cursor_h.deinit();
    if (comptime terminalpkg.compression_enabled)
        self.compression.deinit();
    self.loop.deinit();

    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(self.alloc);
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("error in renderer err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    defer log.debug("renderer thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"renderer".*);
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .renderer,
        .surface = self.renderer.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Setup our thread QoS
    self.setQosClass();

    // Run our loop start/end callbacks if the renderer cares.
    const has_loop = @hasDecl(rendererpkg.Renderer, "loopEnter");
    if (has_loop) try self.renderer.loopEnter(self);
    defer if (has_loop) self.renderer.loopExit();

    // Run our thread start/end callbacks. This is important because some
    // renderers have to do per-thread setup. For example, OpenGL has to set
    // some thread-local state since that is how it works.
    try self.renderer.threadEnter(self.surface);
    defer self.renderer.threadExit();

    // DirectX: xev's IOCP loop stalls after D3D11 device creation.
    // Use a simple native render loop instead.
    if (use_native_loop) {
        self.stop_requested.store(false, .seq_cst);
    } else {
        self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
        self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);
        self.draw_now.wait(&self.loop, &self.draw_now_c, Thread, self, drawNowCallback);
        try self.wakeup.notify();

        // Start blinking the cursor.
        self.cursor_h.run(
            &self.loop,
            &self.cursor_c,
            cursorBlinkInterval(),
            Thread,
            self,
            cursorTimerCallback,
        );

        // Arm the animation timer in case the renderer already needs
        // animation wakes (e.g. custom shaders loaded at startup).
        self.armAnimationTimer();
    }

    // Run
    log.debug("starting renderer thread", .{});
    defer log.debug("starting renderer thread shutdown", .{});

    if (use_native_loop) {
        // Native Windows render loop for DirectX.
        // xev's IOCP event loop is incompatible with D3D11 device context,
        // so we use a simple poll loop similar to Windows Terminal's RenderThread.
        //
        // Register stop handler: when Surface calls stop.notify(), run the
        // xev loop briefly to process it and set our atomic flag.
        self.stop_requested.store(false, .monotonic);
        self.stop.wait(&self.loop, &self.stop_c, Thread, self, nativeStopCallback);

        // Register the wakeup / draw-now asyncs on the same polled loop.
        // Without these, every renderer_wakeup.notify() from termio /
        // Surface (PTY output, resize, IME preedit, refresh) is silently
        // dropped and the only thing that ever produces frames is the
        // unconditional poll below — which forces redrawing every cycle
        // "just in case". Delivery uses the identical mechanism as the
        // stop async above, which is proven to fire through
        // loop.run(.no_wait).
        self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
        self.draw_now.wait(&self.loop, &self.draw_now_c, Thread, self, drawNowCallback);

        // Prime the first frame (mirrors the xev branch).
        self.flags.render_requested = true;

        const win = @import("../os/windows.zig");
        const k32 = win.exp.kernel32;
        const GetTickCount64 = k32.GetTickCount64;

        // Use high-resolution waitable timer to avoid timeBeginPeriod(1)
        // which changes the system-wide timer resolution (affects all processes,
        // increases power consumption on laptops).
        //
        // CREATE_WAITABLE_TIMER_HIGH_RESOLUTION requires Windows 10 1803+.
        // On older versions, CreateWaitableTimerExW returns null because the
        // flag is unrecognized, and we fall back to timeBeginPeriod(1) + Sleep.
        const timer = k32.CreateWaitableTimerExW(
            null,
            null,
            win.exp.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
            0x1F0003, // TIMER_ALL_ACCESS
        );
        defer if (timer) |t| std.os.windows.CloseHandle(t);

        // Fallback to timeBeginPeriod if high-resolution timer is not available
        const use_legacy_timer = (timer == null);
        if (use_legacy_timer) {
            _ = win.exp.winmm.timeBeginPeriod(1);
        }
        defer if (use_legacy_timer) {
            _ = win.exp.winmm.timeEndPeriod(1);
        };

        var last_blink: u64 = GetTickCount64();
        var last_forced: u64 = GetTickCount64();
        var last_animation: u64 = GetTickCount64();

        while (!self.stop_requested.load(.monotonic)) {
            // Poll xev (non-blocking): stop / wakeup / draw-now asyncs
            // are all delivered here.
            _ = self.loop.run(.no_wait) catch |err|
                log.err("error in xev poll err={}", .{err});

            // Adaptive pacing: 4ms (~240fps) when focused, 16ms (~60fps) when not
            const sleep_ms: u32 = if (self.flags.focused) 4 else 16;

            const now = GetTickCount64();
            self.nativeRenderCycle(&last_blink, &last_forced, &last_animation, now, sleep_ms);

            if (timer) |t| {
                // Negative value = relative time in 100ns units
                var due_time: win.LARGE_INTEGER = -@as(i64, sleep_ms) * 10000;
                if (k32.SetWaitableTimerEx(t, &due_time, 0, null, null, null, 0).toBool()) {
                    _ = k32.WaitForSingleObject(t, sleep_ms * 2);
                } else {
                    k32.Sleep(sleep_ms);
                }
            } else {
                k32.Sleep(sleep_ms);
            }
        }
    } else {
        _ = try self.loop.run(.until_done);
    }
}

fn setQosClass(self: *const Thread) void {
    // Thread QoS classes are only relevant on macOS.
    if (comptime !builtin.target.os.tag.isDarwin()) return;

    const class: internal_os.macos.QosClass = class: {
        // If we aren't visible (our view is fully occluded) then we
        // always drop our rendering priority down because it's just
        // mostly wasted work.
        //
        // The renderer itself should be doing this as well (for example
        // Metal will stop our DisplayLink) but this also helps with
        // general forced updates and CPU usage i.e. a rebuild cells call.
        if (!self.flags.visible) break :class .utility;

        // If we're not focused, but we're visible, then we set a higher
        // than default priority because framerates still matter but it isn't
        // as important as when we're focused.
        if (!self.flags.focused) break :class .user_initiated;

        // We are focused and visible, we are the definition of user interactive.
        break :class .user_interactive;
    };

    if (internal_os.macos.setQosClass(class)) {
        log.debug("thread QoS class set class={}", .{class});
    } else |err| {
        log.warn("error setting QoS class err={}", .{err});
    }
}

/// Drain the mailbox. Returns true when at least one message was
/// processed — the native render loop uses this as a "state may have
/// changed, redraw" signal, which also covers producers whose wakeup
/// notify was dropped but whose mailbox push succeeded.
fn drainMailbox(self: *Thread) !bool {
    // There's probably a more elegant way to do this...
    //
    // This is effectively an @autoreleasepool{} block, which we need in
    // order to ensure that autoreleased objects are properly released.
    const pool = if (builtin.os.tag.isDarwin())
        @import("objc").AutoreleasePool.init()
    else
        void;
    defer if (builtin.os.tag.isDarwin()) pool.deinit();

    var drained = false;
    while (self.mailbox.pop(global.io())) |message| {
        drained = true;
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .crash => @panic("crash request, crashing intentionally"),

            .visible => |v| visible: {
                // If our state didn't change we do nothing.
                if (self.flags.visible == v) break :visible;

                // Set our visible state
                self.flags.visible = v;

                // Visibility affects our QoS class
                self.setQosClass();

                // If we became visible then we immediately rebuild cells
                // (renderCallback skips updateFrame while invisible) and
                // draw. Going through renderCallback also reschedules
                // any Kitty graphics animation wakeup that lapsed
                // while we were invisible.
                if (v) _ = renderCallback(self, undefined, undefined, {});

                // Notify the renderer so it can update any state.
                self.renderer.setVisible(v);

                // Note that we're explicitly today not stopping any
                // cursor timers, draw timers, etc. These things have very
                // little resource cost and properly maintaining their active
                // state across different transitions is going to be bug-prone,
                // so its easier to just let them keep firing and have them
                // check the visible state themselves to control their behavior.
            },

            .focus => |v| focus: {
                // If our state didn't change we do nothing.
                if (self.flags.focused == v) break :focus;

                // Set our state
                self.flags.focused = v;

                // Focus affects our QoS class
                self.setQosClass();

                // Set it on the renderer
                try self.renderer.setFocus(v);

                if (use_native_loop) {
                    // Native loop: cursor blink is managed by the poll loop.
                    // Just show cursor immediately on focus gain.
                    if (v) self.flags.cursor_blink_visible = true;
                } else {
                    // Focus gates custom shader animation, so re-arm
                    // the animation timer for the new state.
                    self.armAnimationTimer();

                    if (!v) {
                        // If we're not focused, then we stop the cursor blink
                        if (self.cursor_c.state() == .active and
                            self.cursor_c_cancel.state() == .dead)
                        {
                            self.cursor_h.cancel(
                                &self.loop,
                                &self.cursor_c,
                                &self.cursor_c_cancel,
                                void,
                                null,
                                cursorCancelCallback,
                            );
                        }
                    } else {
                        // If we're focused, we immediately show the cursor again
                        // and then restart the timer.
                        if (self.cursor_c.state() != .active) {
                            self.flags.cursor_blink_visible = true;
                            self.cursor_h.run(
                                &self.loop,
                                &self.cursor_c,
                                cursorBlinkInterval(),
                                Thread,
                                self,
                                cursorTimerCallback,
                            );
                        }
                    }
                }
            },

            .reset_cursor_blink => {
                self.flags.cursor_blink_visible = true;
                self.flags.cursor_blink_reset = true;
                if (!use_native_loop) {
                    if (self.cursor_c.state() == .active) {
                        self.cursor_h.reset(
                            &self.loop,
                            &self.cursor_c,
                            &self.cursor_c_cancel,
                            cursorBlinkInterval(),
                            Thread,
                            self,
                            cursorTimerCallback,
                        );
                    }
                }
            },

            .font_grid => |grid| {
                self.renderer.setFontGrid(grid.grid);
                grid.set.deref(grid.old_key);
            },

            .resize => |v| self.renderer.setScreenSize(v),

            .change_config => |config| {
                defer config.alloc.destroy(config.thread);
                defer config.alloc.destroy(config.impl);
                try self.changeConfig(config.thread);
                try self.renderer.changeConfig(config.impl);

                if (!use_native_loop) {
                    // The config affects what animation wakes the
                    // renderer needs (custom shaders, animation mode).
                    self.armAnimationTimer();
                }
            },

            .search_viewport_matches => |v| {
                // Note we don't free the new value because we expect our
                // allocators to match.
                if (self.renderer.search_matches) |*m| m.arena.deinit();
                self.renderer.search_matches = v;
                self.renderer.search_matches_dirty = true;
            },

            .search_selected_match => |v| {
                // Note we don't free the new value because we expect our
                // allocators to match.
                if (self.renderer.search_selected_match) |*m| m.arena.deinit();
                self.renderer.search_selected_match = v;
                self.renderer.search_matches_dirty = true;
            },

            .inspector => |v| {
                self.flags.has_inspector = v;
            },

            .macos_display_id => |v| {
                if (@hasDecl(rendererpkg.Renderer, "setMacOSDisplayID")) {
                    try self.renderer.setMacOSDisplayID(v, &self.draw_now);
                }
            },
        }
    }

    return drained;
}

fn changeConfig(self: *Thread, config: *const DerivedConfig) !void {
    // A newly enabled scheduler must reconsider existing history even when no
    // terminal activity occurred while compression was disabled.
    if (comptime terminalpkg.compression_enabled) {
        if (!self.config.scrollback_compression and
            config.scrollback_compression)
        {
            self.compression.activity = null;
        }
    }

    self.config = config.*;
}

/// Trigger a draw. This will not update frame data or anything, it will
/// just trigger a draw/paint.
fn drawFrame(self: *Thread, now: bool) void {
    // If we're invisible, we do not draw.
    if (!self.flags.visible) return;

    // If the renderer is managing a vsync on its own, we only draw
    // when we're forced to via `now`.
    if (!now and self.renderer.hasVsync()) return;

    if (apprt.must_draw_from_app_thread) {
        _ = self.app_mailbox.push(
            .{ .redraw_surface = self.surface },
            .{ .instant = {} },
        );
    } else {
        self.renderer.drawFrame(false) catch |err|
            log.warn("error drawing err={}", .{err});
    }
}

/// Perform one render cycle for the native render loop.
///
/// Hybrid cadence:
///
///   * Focused surface: render every cycle, exactly like the loop
///     always did. On a high-refresh monitor (240 Hz = 4.2 ms/frame)
///     the 4 ms poll IS the frame pacing — producing frames only on
///     wakeup events makes motion visibly choppier and adds a poll
///     interval of input latency, and the focused surface is the one
///     the user is typing into. Only one surface is focused at a time
///     (the host forwards focus via ghostty_surface_set_focus), so
///     the continuous cost is bounded to a single window.
///
///   * Unfocused surfaces: event-driven — a frame is only produced
///     when something asked for one (wakeup async, mailbox activity,
///     or the periodic safety net). Background windows still update
///     live on PTY output but stop presenting when idle, instead of
///     burning 60+ fps on content nobody is interacting with.
fn nativeRenderCycle(
    self: *Thread,
    last_blink: *u64,
    last_forced: *u64,
    last_animation: *u64,
    now: u64,
    poll_ms: u64,
) void {
    const had_messages = self.drainMailbox() catch |err| blk: {
        log.err("error draining mailbox err={}", .{err});
        break :blk false;
    };

    if (self.flags.cursor_blink_reset) {
        self.flags.cursor_blink_reset = false;
        last_blink.* = now;
    }

    // Toggle the blinking cursor while focused. Mirrors the xev branch,
    // which cancels the cursor timer on focus loss; the .focus mailbox
    // handler already resets cursor_blink_visible on both transitions.
    var blink_toggled = false;
    if (self.flags.focused and now - last_blink.* >= cursorBlinkInterval()) {
        self.flags.cursor_blink_visible = !self.flags.cursor_blink_visible;
        last_blink.* = now;
        blink_toggled = true;
    }

    // Safety net: periodically force a full update+draw in case a
    // producer's wakeup notify was dropped (mailbox pushes and notifies
    // can fail independently), so a lost notify degrades to a briefly
    // stale frame instead of a permanently stale one.
    const forced = now - last_forced.* >= NATIVE_FORCED_REDRAW_INTERVAL;

    // Focused surface renders unconditionally — see the doc comment.
    const continuous = self.flags.focused;

    if (continuous or self.flags.render_requested or had_messages or blink_toggled or forced) {
        self.flags.render_requested = false;
        last_forced.* = now;
        last_animation.* = now;
        self.renderer.updateFrame(
            self.state,
            self.flags.cursor_blink_visible,
        ) catch |err|
            log.warn("error rendering err={}", .{err});
        self.drawFrame(false);
        return;
    }

    if (self.flags.draw_now_requested) {
        self.flags.draw_now_requested = false;
        self.drawFrame(true);
        return;
    }

    // Animations (custom shaders, Kitty graphics frames): the xev
    // branch arms a timer off animationWake; this loop asks every
    // cycle instead and acts once the wake is due, i.e. within the
    // next poll or when its delay has elapsed since the last
    // animation-driven frame.
    const wake = self.renderer.animationWake() orelse return;
    if (wake.delay_ms > poll_ms and now - last_animation.* < wake.delay_ms) return;
    last_animation.* = now;
    switch (wake.kind) {
        .update => {
            self.renderer.updateFrame(
                self.state,
                self.flags.cursor_blink_visible,
            ) catch |err|
                log.warn("error rendering err={}", .{err});
            self.drawFrame(false);
        },
        .draw => self.drawFrame(false),
    }
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    const t = self_.?;

    // Native loop: defer all render work to nativeRenderCycle so no
    // D3D calls happen inside xev callback dispatch (this backend's
    // IOCP loop has a history of stalling around D3D11 work). The
    // cycle picks the flag up within one poll interval.
    if (comptime use_native_loop) {
        t.flags.render_requested = true;
        return .rearm;
    }

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    _ = t.drainMailbox() catch |err|
        log.err("error draining mailbox err={}", .{err});

    // Render immediately
    _ = renderCallback(t, undefined, undefined, {});

    // PageList mutations maintain their own compression dirty state. Checking
    // it here covers output, resize, and viewport scrolling uniformly.
    t.compression.wake(t);

    // The below is not used anymore but if we ever want to introduce
    // a configuration to introduce a delay to coalesce renders, we can
    // use this.
    //
    // // If the timer is already active then we don't have to do anything.
    // if (t.render_c.state() == .active) return .rearm;
    //
    // // Timer is not active, let's start it
    // t.render_h.run(
    //     &t.loop,
    //     &t.render_c,
    //     10,
    //     Thread,
    //     t,
    //     renderCallback,
    // );

    return .rearm;
}

fn drawNowCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in draw now err={}", .{err});
        return .rearm;
    };

    // Draw immediately
    const t = self_.?;

    // Native loop: same deferral as wakeupCallback — keep D3D work
    // out of xev dispatch.
    if (comptime use_native_loop) {
        t.flags.draw_now_requested = true;
        return .rearm;
    }

    t.drawFrame(true);

    return .rearm;
}

fn renderCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // Sent when a scheduled animation wakeup is superseded by a
        // newer one (Timer.reset cancels the pending run). Nothing to
        // do; the replacement timer carries on.
        error.Canceled => return .disarm,
        else => unreachable,
    };
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    // If we're not visible there's no point spending CPU rebuilding cells —
    // we'll catch up when the .visible mailbox message flips us back on.
    // Kitty graphics animations pause with us and resume on visibility.
    if (!t.flags.visible) return .disarm;

    // Update our frame data
    t.renderer.updateFrame(
        t.state,
        t.flags.cursor_blink_visible,
    ) catch |err|
        log.warn("error rendering err={}", .{err});

    // Draw
    t.drawFrame(false);

    // Schedule the next animation wake, if the renderer needs one.
    t.armAnimationTimer();

    return .disarm;
}

/// Schedule the animation timer for the renderer's next animation
/// wake, if it needs one.
///
/// This is called after every frame update or animation draw and
/// whenever the wake inputs change (focus, config, visibility
/// regain). Resetting a pending timer is always safe: every call
/// recomputes the wake, so the deadline only ever moves toward the
/// actual next wake.
fn armAnimationTimer(self: *Thread) void {
    const wake = self.renderer.animationWake() orelse return;
    self.animation_wake = wake.kind;
    self.render_h.reset(
        &self.loop,
        &self.render_c,
        &self.render_c_cancel,
        wake.delay_ms,
        Thread,
        self,
        animationTimerCallback,
    );
}

fn animationTimerCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // Sent when a scheduled animation wake is superseded by a
        // newer one (Timer.reset cancels the pending run). Nothing to
        // do; the replacement timer carries on.
        error.Canceled => return .disarm,
        else => unreachable,
    };
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("animation callback fired without data set", .{});
        return .disarm;
    };

    // Animations pause entirely while we're invisible; the .visible
    // mailbox message re-arms us when we can be seen again.
    if (!t.flags.visible) return .disarm;

    switch (t.animation_wake) {
        // Frame data must be updated (a Kitty animation frame is
        // due). renderCallback updates, draws, and re-arms us.
        .update => return renderCallback(
            t,
            undefined,
            undefined,
            {},
        ),

        // A redraw alone suffices (custom shader time uniform).
        // Draw calls don't update from the terminal state so they
        // are much cheaper than a frame update.
        .draw => {
            t.drawFrame(false);
            t.armAnimationTimer();
            return .disarm;
        },
    }
}

fn cursorTimerCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // This is sent when our timer is canceled. That's fine.
        error.Canceled => return .disarm,

        else => {
            log.warn("error in cursor timer callback err={}", .{err});
            unreachable;
        },
    };

    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    t.flags.cursor_blink_visible = !t.flags.cursor_blink_visible;
    t.wakeup.notify() catch {};

    t.cursor_h.run(
        &t.loop,
        &t.cursor_c,
        cursorBlinkInterval(),
        Thread,
        t,
        cursorTimerCallback,
    );
    return .disarm;
}

fn cursorCancelCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    // This makes it easier to work across platforms where different platforms
    // support different sets of errors, so we just unify it.
    const CancelError = xev.Timer.CancelError || error{
        Canceled,
        NotFound,
        Unexpected,
    };

    _ = r catch |err| switch (@as(CancelError, @errorCast(err))) {
        error.Canceled => {}, // success
        error.NotFound => {}, // completed before it could cancel
        else => {
            log.warn("error in cursor cancel callback err={}", .{err});
            unreachable;
        },
    };

    return .disarm;
}

// fn prepFrameCallback(h: *libuv.Prepare) void {
//     _ = h;
//
//     tracy.frameMark();
// }

fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}

/// Stop callback for native render loop. Sets the atomic flag
/// so the poll loop exits.
fn nativeStopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch return .disarm;
    if (self_) |self| {
        if (use_native_loop) {
            self.stop_requested.store(true, .monotonic);
        }
    }
    return .disarm;
}

/// Returns the interval for the blinking cursor in milliseconds.
fn cursorBlinkInterval() u64 {
    if (std.valgrind.runningOnValgrind() > 0) {
        // If we're running under Valgrind, the cursor blink adds enough
        // churn that it makes some stalls annoying unless you're on a
        // super powerful computer, so we delay it.
        //
        // This is a hack, we should change some of our cursor timer
        // logic to be more efficient:
        // https://github.com/ghostty-org/ghostty/issues/8003
        return CURSOR_BLINK_INTERVAL * 5;
    }

    return CURSOR_BLINK_INTERVAL;
}

/// Schedules incremental terminal compression after renderer activity stops.
///
/// This owns all renderer-specific compression state. The terminal decides
/// when compression-relevant activity changes and performs the actual work;
/// the renderer only provides idle scheduling and avoids waiting for the
/// terminal lock.
const Compression = struct {
    const idle_interval = 250;
    const step_interval = 1;

    timer: xev.Timer,
    completion: xev.Completion = .{},
    reset_completion: xev.Completion = .{},
    activity: ?u64 = null,

    fn init() !Compression {
        return .{ .timer = try xev.Timer.init() };
    }

    fn deinit(self: *Compression) void {
        self.timer.deinit();
    }

    /// Start or postpone compression after a renderer wake.
    fn wake(self: *Compression, thread: *Thread) void {
        // If we have no compression then don't do anything.
        if (comptime !terminalpkg.compression_enabled) return;
        if (!thread.config.scrollback_compression) return;

        // PageList activity, rather than a generic renderer wake, restarts the
        // idle interval. In particular, the inspector wakes the renderer every
        // frame without changing terminal contents and must not starve this
        // timer indefinitely.
        if (thread.state.mutex.tryLock()) {
            defer thread.state.mutex.unlock(global.io());
            const activity = thread.state.terminal.compressionActivity();
            if (self.activity == activity) return;
            self.activity = activity;
        } else if (self.completion.state() == .active) {
            // Contention doesn't prove that compression-relevant activity
            // changed. Keep an existing deadline so frequent inspector frames
            // cannot postpone compression forever. The timer rechecks both the
            // activity token and lock availability before doing any work.
            return;
        }

        // Contention may mean parsing is active. Scheduling is a harmless
        // false positive when no compression work is actually pending, but is
        // necessary when no timer is already active.
        self.schedule(thread, idle_interval);
    }

    /// Start the one-shot timer, or move its deadline if it is already active.
    fn schedule(self: *Compression, thread: *Thread, delay_ms: u64) void {
        self.timer.reset(
            &thread.loop,
            &self.completion,
            &self.reset_completion,
            delay_ms,
            Thread,
            thread,
            timerCallback,
        );
    }

    fn timerCallback(
        thread_: ?*Thread,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = result catch |err| switch (err) {
            error.Canceled => return .disarm,
            else => {
                log.warn("error in compression timer err={}", .{err});
                return .disarm;
            },
        };

        const thread = thread_ orelse return .disarm;
        const self = &thread.compression;

        if (self.step(thread)) |delay| self.schedule(thread, delay);
        return .disarm;
    }

    /// Try one bounded step without waiting for the terminal lock. The return
    /// value is the delay before another attempt, or null when work is done.
    fn step(self: *Compression, thread: *Thread) ?u64 {
        if (!thread.config.scrollback_compression) return null;

        const state = thread.state;
        if (!state.mutex.tryLock()) return idle_interval;
        defer state.mutex.unlock(global.io());

        const activity = state.terminal.compressionActivity();
        if (self.activity != activity) {
            self.activity = activity;
            return idle_interval;
        }

        return switch (state.terminal.compress(.incremental)) {
            .pending => step_interval,
            .unsupported,
            .complete,
            => null,
        };
    }
};

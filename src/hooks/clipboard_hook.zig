const std = @import("std");
const builtin = @import("builtin");
const hook = @import("hook");
const Hook = hook.Hook;
const HookError = hook.HookError;
const TranscriptionResult = hook.TranscriptionResult;

pub const ClipboardHook = struct {
    pub fn process(ptr: *anyopaque, result: *const TranscriptionResult) HookError!void {
        _ = ptr;

        if (result.text.len == 0) return;

        switch (builtin.os.tag) {
            .linux => copyLinux(result.text) catch return HookError.HookFailed,
            .windows => copyWindows(result.text) catch return HookError.HookFailed,
            else => return HookError.HookFailed,
        }

        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("(copied to clipboard)\n", .{}) catch {};
    }

    fn copyLinux(text: []const u8) !void {
        const allocator = std.heap.page_allocator;

        // Try wl-copy first (Wayland)
        {
            var child = std.process.Child.init(&.{"wl-copy"}, allocator);
            child.stdin_behavior = .Pipe;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            child.spawn() catch {
                // wl-copy not available, fall through to xclip
                return copyLinuxXclip(text);
            };

            if (child.stdin) |stdin| {
                stdin.writeAll(text) catch {};
                stdin.close();
                child.stdin = null;
            }

            const term = child.wait() catch return error.ClipboardFailed;
            switch (term) {
                .Exited => |code| if (code != 0) return copyLinuxXclip(text),
                else => return copyLinuxXclip(text),
            }
        }
    }

    fn copyLinuxXclip(text: []const u8) !void {
        const allocator = std.heap.page_allocator;

        var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard" }, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return error.ClipboardFailed;

        if (child.stdin) |stdin| {
            stdin.writeAll(text) catch {};
            stdin.close();
            child.stdin = null;
        }

        const term = child.wait() catch return error.ClipboardFailed;
        switch (term) {
            .Exited => |code| if (code != 0) return error.ClipboardFailed,
            else => return error.ClipboardFailed,
        }
    }

    fn copyWindows(text: []const u8) !void {
        const allocator = std.heap.page_allocator;

        // Use powershell with stdin piping to avoid shell escaping issues
        var child = std.process.Child.init(
            &.{ "powershell.exe", "-Command", "$input | Set-Clipboard" },
            allocator,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return error.ClipboardFailed;

        if (child.stdin) |stdin| {
            stdin.writeAll(text) catch {};
            stdin.close();
            child.stdin = null;
        }

        const term = child.wait() catch return error.ClipboardFailed;
        switch (term) {
            .Exited => |code| if (code != 0) return error.ClipboardFailed,
            else => return error.ClipboardFailed,
        }
    }

    pub fn hookImpl(self: *ClipboardHook) Hook {
        return Hook{
            .ptr = self,
            .processFn = process,
        };
    }
};

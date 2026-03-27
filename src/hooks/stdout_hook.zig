const std = @import("std");
const hook = @import("hook");
const Hook = hook.Hook;
const HookError = hook.HookError;
const TranscriptionResult = hook.TranscriptionResult;

pub const StdoutHook = struct {
    verbose: bool = false,

    pub fn process(ptr: *anyopaque, result: *const TranscriptionResult) HookError!void {
        const self: *StdoutHook = @ptrCast(@alignCast(ptr));
        const stdout = std.fs.File.stdout().deprecatedWriter();

        if (self.verbose) {
            for (result.segments) |seg| {
                stdout.print("[{d} -> {d}] {s}\n", .{ seg.t0, seg.t1, seg.text }) catch {
                    return HookError.HookFailed;
                };
            }
        } else {
            stdout.print("{s}\n", .{result.text}) catch {
                return HookError.HookFailed;
            };
        }
    }

    pub fn hookImpl(self: *StdoutHook) Hook {
        return Hook{
            .ptr = self,
            .processFn = process,
        };
    }
};

const hook = @import("hook");
const console = @import("console");
const Hook = hook.Hook;
const HookError = hook.HookError;
const TranscriptionResult = hook.TranscriptionResult;

pub const StdoutHook = struct {
    verbose: bool = false,

    pub fn process(ptr: *anyopaque, result: *const TranscriptionResult) HookError!void {
        const self: *StdoutHook = @ptrCast(@alignCast(ptr));
        const out = console.stdout();

        if (self.verbose) {
            for (result.segments) |seg| {
                out.print("[{d} -> {d}] {s}\n", .{ seg.t0, seg.t1, seg.text });
            }
        } else {
            out.print("{s}\n", .{result.text});
        }
    }

    pub fn hookImpl(self: *StdoutHook) Hook {
        return Hook{
            .ptr = self,
            .processFn = process,
        };
    }
};

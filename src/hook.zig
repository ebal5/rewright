const whisper = @import("whisper");
pub const TranscriptionResult = whisper.TranscriptionResult;

pub const HookError = error{ HookFailed, NetworkError, Timeout };

pub const Hook = struct {
    ptr: *anyopaque,
    processFn: *const fn (ptr: *anyopaque, result: *const TranscriptionResult) HookError!void,

    pub fn process(self: Hook, result: *const TranscriptionResult) HookError!void {
        return self.processFn(self.ptr, result);
    }
};

pub const HookDispatcher = struct {
    hooks: [16]?Hook = .{null} ** 16,
    count: usize = 0,

    pub fn register(self: *HookDispatcher, h: Hook) void {
        if (self.count < self.hooks.len) {
            self.hooks[self.count] = h;
            self.count += 1;
        }
    }

    pub fn dispatch(self: *HookDispatcher, result: *const TranscriptionResult) HookError!void {
        for (self.hooks[0..self.count]) |maybe_hook| {
            if (maybe_hook) |hook| {
                try hook.process(result);
            }
        }
    }
};

const std = @import("std");
const hook_mod = @import("hook");
const Hook = hook_mod.Hook;
const HookError = hook_mod.HookError;
const HookDispatcher = hook_mod.HookDispatcher;
const TranscriptionResult = hook_mod.TranscriptionResult;

/// A test hook implementation that counts calls and records the last text seen.
const TestHook = struct {
    call_count: usize = 0,
    last_text: []const u8 = "",

    fn process(ptr: *anyopaque, result: *const TranscriptionResult) HookError!void {
        const self: *TestHook = @ptrCast(@alignCast(ptr));
        self.call_count += 1;
        self.last_text = result.text;
    }

    fn hookImpl(self: *TestHook) Hook {
        return Hook{
            .ptr = self,
            .processFn = process,
        };
    }
};

test "hook dispatch calls all registered hooks" {
    var hook1 = TestHook{};
    var hook2 = TestHook{};

    var dispatcher = HookDispatcher{};
    dispatcher.register(hook1.hookImpl());
    dispatcher.register(hook2.hookImpl());

    const result = TranscriptionResult{
        .text = "hello world",
        .segments = &.{},
    };

    try dispatcher.dispatch(&result);

    try std.testing.expectEqual(@as(usize, 1), hook1.call_count);
    try std.testing.expectEqual(@as(usize, 1), hook2.call_count);
    try std.testing.expectEqualStrings("hello world", hook1.last_text);
    try std.testing.expectEqualStrings("hello world", hook2.last_text);
}

test "empty dispatcher does not crash" {
    var dispatcher = HookDispatcher{};
    const result = TranscriptionResult{
        .text = "test",
        .segments = &.{},
    };
    try dispatcher.dispatch(&result);
}

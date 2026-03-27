const std = @import("std");
const llm_hook = @import("llm_hook");

test "format chat completions request body" {
    var buf: [4096]u8 = undefined;
    const body = try llm_hook.formatRequestBody(
        &buf,
        "gpt-4",
        "You are a helpful assistant.",
        "Hello world",
        0.3,
        4096,
    );

    // Parse the generated JSON to verify structure
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Verify model
    try std.testing.expectEqualStrings("gpt-4", root.get("model").?.string);

    // Verify messages array
    const messages = root.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);

    // System message
    try std.testing.expectEqualStrings("system", messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("You are a helpful assistant.", messages.items[0].object.get("content").?.string);

    // User message
    try std.testing.expectEqualStrings("user", messages.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("Hello world", messages.items[1].object.get("content").?.string);

    // Verify temperature and max_tokens
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), root.get("temperature").?.float, 0.01);
    try std.testing.expectEqual(@as(i64, 4096), root.get("max_tokens").?.integer);
}

test "format request body escapes special characters" {
    var buf: [4096]u8 = undefined;
    const body = try llm_hook.formatRequestBody(
        &buf,
        "gpt-4",
        "line1\nline2",
        "He said \"hello\"\tand\\more",
        0.5,
        100,
    );

    // Parse to verify the escaped strings are valid JSON
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const messages = parsed.value.object.get("messages").?.array;
    try std.testing.expectEqualStrings("line1\nline2", messages.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("He said \"hello\"\tand\\more", messages.items[1].object.get("content").?.string);
}

test "parse chat completions response" {
    const response =
        \\{"choices":[{"message":{"content":"hello world yeah"}}]}
    ;
    const text = try llm_hook.parseResponseText(response);
    try std.testing.expectEqualStrings("hello world yeah", text);
}

test "parse empty response returns error" {
    const response =
        \\{"choices":[]}
    ;
    try std.testing.expectError(error.NoChoicesInResponse, llm_hook.parseResponseText(response));
}

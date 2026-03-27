const std = @import("std");
const hook = @import("hook");
const Hook = hook.Hook;
const HookError = hook.HookError;
const TranscriptionResult = hook.TranscriptionResult;

pub const LlmConfig = struct {
    api_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    system_prompt: []const u8,
    temperature: f32 = 0.3,
    max_tokens: u32 = 4096,
    timeout_ms: u32 = 30_000,
};

pub const LlmHook = struct {
    config: LlmConfig,

    pub fn process(ptr: *anyopaque, result: *const TranscriptionResult) HookError!void {
        const self: *LlmHook = @ptrCast(@alignCast(ptr));

        // Format request body
        var req_buf: [32 * 1024]u8 = undefined;
        const body = formatRequestBody(
            &req_buf,
            self.config.model,
            self.config.system_prompt,
            result.text,
            self.config.temperature,
            self.config.max_tokens,
        ) catch return HookError.HookFailed;

        // Make HTTP request
        const allocator = std.heap.page_allocator;
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        const uri = std.Uri.parse(self.config.api_url) catch return HookError.HookFailed;

        // Build authorization header value
        var auth_buf: [512]u8 = undefined;
        const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.config.api_key}) catch return HookError.HookFailed;

        var req = client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Authorization", .value = auth_value },
            },
        }) catch return HookError.NetworkError;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = req.sendBody(&.{}) catch return HookError.NetworkError;
        body_writer.writer.writeAll(body) catch return HookError.NetworkError;
        body_writer.end() catch return HookError.NetworkError;
        req.connection.?.flush() catch return HookError.NetworkError;

        var response = req.receiveHead(&.{}) catch return HookError.NetworkError;

        if (response.head.status != .ok) {
            return HookError.HookFailed;
        }

        // Read response body
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);

        var resp_buf: [32 * 1024]u8 = undefined;
        var resp_len: usize = 0;
        while (true) {
            const n = reader.readSliceShort(resp_buf[resp_len..]) catch break;
            if (n == 0) break;
            resp_len += n;
            if (resp_len >= resp_buf.len) break;
        }

        const response_body = resp_buf[0..resp_len];

        // Parse response
        const cleaned_text = parseResponseText(response_body) catch return HookError.HookFailed;

        // Write to stdout
        const stdout = std.fs.File.stdout().deprecatedWriter();
        stdout.print("{s}\n", .{cleaned_text}) catch return HookError.HookFailed;
    }

    pub fn hookImpl(self: *LlmHook) Hook {
        return Hook{
            .ptr = self,
            .processFn = process,
        };
    }
};

/// Write a JSON-escaped string (without surrounding quotes) to the writer.
pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Format an OpenAI chat completions request body into the provided buffer.
pub fn formatRequestBody(
    buf: []u8,
    model: []const u8,
    system_prompt: []const u8,
    user_text: []const u8,
    temperature: f32,
    max_tokens: u32,
) ![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    try writer.writeAll("{\"model\":\"");
    try writeJsonString(writer, model);
    try writer.writeAll("\",\"messages\":[{\"role\":\"system\",\"content\":\"");
    try writeJsonString(writer, system_prompt);
    try writer.writeAll("\"},{\"role\":\"user\",\"content\":\"");
    try writeJsonString(writer, user_text);
    try writer.writeAll("\"}],\"temperature\":");
    try writer.print("{d:.1}", .{temperature});
    try writer.writeAll(",\"max_tokens\":");
    try writer.print("{d}", .{max_tokens});
    try writer.writeAll("}");

    return fbs.getWritten();
}

/// Parse the assistant's reply text from an OpenAI chat completions response.
pub fn parseResponseText(response_body: []const u8) ![]const u8 {
    const allocator = std.heap.page_allocator;

    const ChatMessage = struct {
        content: []const u8,
    };
    const Choice = struct {
        message: ChatMessage,
    };
    const ChatResponse = struct {
        choices: []const Choice,
    };

    const parsed = std.json.parseFromSlice(ChatResponse, allocator, response_body, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidResponse;
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) {
        return error.NoChoicesInResponse;
    }

    const content = parsed.value.choices[0].message.content;

    // Copy to static buffer since parsed data will be freed
    const static = struct {
        var buf: [32 * 1024]u8 = undefined;
    };
    if (content.len > static.buf.len) {
        return error.ResponseTooLarge;
    }
    @memcpy(static.buf[0..content.len], content);
    return static.buf[0..content.len];
}

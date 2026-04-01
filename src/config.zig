const std = @import("std");
const builtin = @import("builtin");

const c_env = @cImport({
    @cInclude("stdlib.h");
});

fn getEnv(key: [*:0]const u8) ?[:0]const u8 {
    const val = c_env.getenv(key) orelse return null;
    return std.mem.span(val);
}

pub const default_system_prompt =
    "You are a helpful assistant that cleans up speech-to-text transcriptions. " ++
    "Fix grammar, punctuation, and formatting while preserving the original meaning.";

pub const Config = struct {
    allocator: std.mem.Allocator,

    whisper_model: []const u8,
    language: []const u8,
    llm_enabled: bool,
    llm_api_url: []const u8,
    llm_api_key: []const u8,
    llm_model: []const u8,
    llm_system_prompt: []const u8,
    clipboard_enabled: bool,
    paste_enabled: bool,

    /// Tracks whether string fields were allocated (true after load from file).
    strings_allocated: bool,

    /// Create a Config with default values. All string fields point to
    /// comptime literals so no allocation is performed.
    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
            .whisper_model = "base",
            .language = "auto",
            .llm_enabled = false,
            .llm_api_url = "https://api.openai.com/v1/chat/completions",
            .llm_api_key = "",
            .llm_model = "gpt-4o-mini",
            .llm_system_prompt = default_system_prompt,
            .clipboard_enabled = true,
            .paste_enabled = false,
            .strings_allocated = false,
        };
    }

    /// Load configuration from the platform-specific JSON file.
    /// Falls back to defaults when the file does not exist or cannot be parsed.
    pub fn load(allocator: std.mem.Allocator) Config {
        var config = init(allocator);

        const path = getConfigFilePath() orelse return config;

        const file = std.fs.cwd().openFile(path, .{}) catch return config;
        defer file.close();

        const max_size = 256 * 1024; // 256 KiB should be more than enough
        const contents = file.readToEndAlloc(allocator, max_size) catch return config;
        defer allocator.free(contents);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return config;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return config;

        const obj = root.object;

        // Helper: extract a string value and dupe it with our allocator.
        const S = struct {
            fn getString(map: std.json.ObjectMap, key: []const u8, alloc: std.mem.Allocator) ?[]const u8 {
                const val = map.get(key) orelse return null;
                if (val != .string) return null;
                return alloc.dupe(u8, val.string) catch return null;
            }
            fn getBool(map: std.json.ObjectMap, key: []const u8) ?bool {
                const val = map.get(key) orelse return null;
                if (val != .bool) return null;
                return val.bool;
            }
        };

        // Once we start reading from the file, mark strings as allocated so
        // deinit knows to free them. We allocate dupes for every string field
        // (even those that keep their default value) to make cleanup uniform.
        config.strings_allocated = true;

        config.whisper_model = S.getString(obj, "whisper_model", allocator) orelse
            allocator.dupe(u8, "base") catch "base";
        config.language = S.getString(obj, "language", allocator) orelse
            allocator.dupe(u8, "auto") catch "auto";
        config.llm_api_url = S.getString(obj, "llm_api_url", allocator) orelse
            allocator.dupe(u8, "https://api.openai.com/v1/chat/completions") catch "https://api.openai.com/v1/chat/completions";
        config.llm_api_key = S.getString(obj, "llm_api_key", allocator) orelse
            allocator.dupe(u8, "") catch "";
        config.llm_model = S.getString(obj, "llm_model", allocator) orelse
            allocator.dupe(u8, "gpt-4o-mini") catch "gpt-4o-mini";
        config.llm_system_prompt = S.getString(obj, "llm_system_prompt", allocator) orelse
            allocator.dupe(u8, default_system_prompt) catch default_system_prompt;

        if (S.getBool(obj, "llm_enabled")) |v| config.llm_enabled = v;
        if (S.getBool(obj, "clipboard_enabled")) |v| config.clipboard_enabled = v;
        if (S.getBool(obj, "paste_enabled")) |v| config.paste_enabled = v;

        return config;
    }

    /// Serialize the configuration to a human-readable JSON file, creating
    /// parent directories as needed.
    pub fn save(self: *const Config) !void {
        const path = getConfigFilePath() orelse return error.NoConfigPath;

        // Ensure the parent directory exists.
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        const writer = file.deprecatedWriter();

        try writer.writeAll("{\n");
        try writeStringField(writer, "whisper_model", self.whisper_model, true);
        try writeStringField(writer, "language", self.language, true);
        try writeBoolField(writer, "llm_enabled", self.llm_enabled, true);
        try writeStringField(writer, "llm_api_url", self.llm_api_url, true);
        try writeStringField(writer, "llm_api_key", self.llm_api_key, true);
        try writeStringField(writer, "llm_model", self.llm_model, true);
        try writeStringField(writer, "llm_system_prompt", self.llm_system_prompt, true);
        try writeBoolField(writer, "clipboard_enabled", self.clipboard_enabled, true);
        try writeBoolField(writer, "paste_enabled", self.paste_enabled, false);
        try writer.writeAll("}\n");
    }

    /// Free all allocated string fields. Safe to call on a Config created
    /// with `init()` (no-op since nothing was allocated).
    pub fn deinit(self: *Config) void {
        if (!self.strings_allocated) return;

        self.allocator.free(self.whisper_model);
        self.allocator.free(self.language);
        self.allocator.free(self.llm_api_url);
        self.allocator.free(self.llm_api_key);
        self.allocator.free(self.llm_model);
        self.allocator.free(self.llm_system_prompt);

        self.strings_allocated = false;
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Resolve the platform-specific config file path into a static buffer.
fn getConfigFilePath() ?[]const u8 {
    const S = struct {
        var buf: [4096]u8 = undefined;
    };

    if (comptime builtin.os.tag == .windows) {
        const appdata = getEnv("APPDATA") orelse return null;
        const path = std.fmt.bufPrint(&S.buf, "{s}\\rewright\\config.json", .{appdata}) catch return null;
        return path;
    } else {
        const xdg = getEnv("XDG_CONFIG_HOME");
        if (xdg) |config_home| {
            const path = std.fmt.bufPrint(&S.buf, "{s}/rewright/config.json", .{config_home}) catch return null;
            return path;
        }
        const home = getEnv("HOME") orelse return null;
        const path = std.fmt.bufPrint(&S.buf, "{s}/.config/rewright/config.json", .{home}) catch return null;
        return path;
    }
}

/// Write a JSON-escaped string value (without surrounding quotes) to the writer.
fn writeJsonEscapedString(writer: anytype, s: []const u8) !void {
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

fn writeStringField(writer: anytype, key: []const u8, value: []const u8, trailing_comma: bool) !void {
    try writer.writeAll("    \"");
    try writer.writeAll(key);
    try writer.writeAll("\": \"");
    try writeJsonEscapedString(writer, value);
    try writer.writeByte('"');
    if (trailing_comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

fn writeBoolField(writer: anytype, key: []const u8, value: bool, trailing_comma: bool) !void {
    try writer.writeAll("    \"");
    try writer.writeAll(key);
    try writer.writeAll("\": ");
    try writer.writeAll(if (value) "true" else "false");
    if (trailing_comma) try writer.writeByte(',');
    try writer.writeByte('\n');
}

const std = @import("std");

const c_env = @cImport({
    @cInclude("stdlib.h");
});

fn getEnv(key: [*:0]const u8) ?[:0]const u8 {
    const val = c_env.getenv(key) orelse return null;
    return std.mem.span(val);
}

fn logErr(comptime fmt: []const u8, args: anytype) void {
    const w = std.fs.File.stderr().deprecatedWriter();
    w.print(fmt, args) catch {};
}

// =========================================================================
// Model Registry
// =========================================================================

pub const ModelInfo = struct {
    name: []const u8,
    filename: []const u8,
    size_desc: []const u8,
    url: []const u8,
};

pub const models = [_]ModelInfo{
    .{
        .name = "tiny",
        .filename = "ggml-tiny.bin",
        .size_desc = "~75MB",
        .url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin",
    },
    .{
        .name = "base",
        .filename = "ggml-base.bin",
        .size_desc = "~142MB",
        .url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
    },
    .{
        .name = "small",
        .filename = "ggml-small.bin",
        .size_desc = "~466MB",
        .url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
    },
    .{
        .name = "medium",
        .filename = "ggml-medium.bin",
        .size_desc = "~1.5GB",
        .url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
    },
    .{
        .name = "large",
        .filename = "ggml-large-v3.bin",
        .size_desc = "~3GB",
        .url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin",
    },
    .{
        .name = "turbo",
        .filename = "ggml-large-v3-turbo.bin",
        .size_desc = "~1.6GB",
        .url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
    },
};

const default_model_name = "base";

fn findModel(name: []const u8) ?*const ModelInfo {
    for (&models) |*m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

// =========================================================================
// Model directory resolution
// =========================================================================

/// Returns the platform-appropriate model directory path.
/// Caller must free the returned slice using page_allocator.
pub fn getModelDir() []const u8 {
    const allocator = std.heap.page_allocator;
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        if (getEnv("LOCALAPPDATA")) |local| {
            return std.fmt.allocPrint(allocator, "{s}\\rewright\\models", .{local}) catch "./models";
        }
        return ".\\models";
    }

    // Linux / other POSIX
    if (getEnv("XDG_CACHE_HOME")) |cache| {
        return std.fmt.allocPrint(allocator, "{s}/rewright/models", .{cache}) catch "./models";
    }
    if (getEnv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.cache/rewright/models", .{home}) catch "./models";
    }
    return "./models";
}

/// Returns full path to a model file (whether or not it exists).
/// Caller must free the returned slice using page_allocator.
pub fn getModelPath(model_name: []const u8) ?[]const u8 {
    const m = findModel(model_name) orelse return null;
    const allocator = std.heap.page_allocator;
    const dir = getModelDir();
    const builtin = @import("builtin");
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ dir, sep, m.filename }) catch null;
}

/// Check whether a model has been downloaded.
pub fn isModelDownloaded(model_name: []const u8) bool {
    const path = getModelPath(model_name) orelse return false;
    // Try to open the file to see if it exists
    if (std.fs.cwd().openFile(path, .{})) |f| {
        f.close();
        return true;
    } else |_| {
        return false;
    }
}

/// Print a table of available models with download status.
pub fn listModels() void {
    const w = std.fs.File.stdout().deprecatedWriter();
    w.print("\nAvailable whisper models:\n\n", .{}) catch {};
    w.print("  {s:<10} {s:<10} {s:<30} {s}\n", .{ "Name", "Size", "Filename", "Status" }) catch {};
    w.print("  {s:<10} {s:<10} {s:<30} {s}\n", .{ "----", "----", "--------", "------" }) catch {};

    for (&models) |*m| {
        const downloaded = isModelDownloaded(m.name);
        const status: []const u8 = if (downloaded) "[downloaded]" else "";
        const marker: []const u8 = if (std.mem.eql(u8, m.name, default_model_name)) " (default)" else "";
        w.print("  {s:<10} {s:<10} {s:<30} {s}{s}\n", .{ m.name, m.size_desc, m.filename, status, marker }) catch {};
    }
    w.print("\nModel directory: {s}\n", .{getModelDir()}) catch {};
}

/// Download a model from HuggingFace.
pub fn downloadModel(model_name: []const u8) !void {
    const m = findModel(model_name) orelse {
        logErr("Error: Unknown model '{s}'\n\nAvailable models: ", .{model_name});
        for (&models) |*mi| {
            logErr("{s} ", .{mi.name});
        }
        logErr("\n", .{});
        std.process.exit(1);
    };

    const path = getModelPath(model_name) orelse {
        logErr("Error: Could not determine model path.\n", .{});
        std.process.exit(1);
    };

    // Check if already downloaded
    if (isModelDownloaded(model_name)) {
        logErr("Already downloaded at {s}\n", .{path});
        return;
    }

    // Ensure directory exists
    const dir = getModelDir();
    std.fs.cwd().makePath(dir) catch |err| {
        logErr("Error: Could not create directory '{s}': {}\n", .{ dir, err });
        return err;
    };

    logErr("Downloading {s} ({s})...\n", .{ m.filename, m.size_desc });

    // HTTP download
    const allocator = std.heap.page_allocator;
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(m.url) catch {
        logErr("Error: Invalid URL.\n", .{});
        return error.InvalidUrl;
    };

    var req = client.request(.GET, uri, .{}) catch {
        logErr("Error: Network error. Check your internet connection and try again.\n", .{});
        return error.NetworkError;
    };
    defer req.deinit();

    req.transfer_encoding = .none;
    var body_writer = req.sendBody(&.{}) catch {
        logErr("Error: Network error during request. Try again.\n", .{});
        return error.NetworkError;
    };
    _ = &body_writer;
    req.connection.?.flush() catch {
        logErr("Error: Network error during flush. Try again.\n", .{});
        return error.NetworkError;
    };

    var response = req.receiveHead(&.{}) catch {
        logErr("Error: Network error receiving response. Try again.\n", .{});
        return error.NetworkError;
    };

    // Follow redirects: HuggingFace returns 302 redirects
    // std.http.Client in Zig 0.15 should handle redirects automatically,
    // but if we get a non-200, report it
    if (response.head.status != .ok) {
        logErr("Error: Server returned HTTP {d}. Try again later.\n", .{@intFromEnum(response.head.status)});
        return error.HttpError;
    }

    const content_length: ?u64 = response.head.content_length;

    // Open output file (write to temp file then rename for atomicity)
    const tmp_path = std.fmt.allocPrint(allocator, "{s}.part", .{path}) catch {
        logErr("Error: Out of memory.\n", .{});
        return error.OutOfMemory;
    };

    const out_file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
        logErr("Error: Could not create file '{s}': {}\n", .{ tmp_path, err });
        return err;
    };
    errdefer {
        out_file.close();
        std.fs.cwd().deleteFile(tmp_path) catch {};
    }

    // Read and write in chunks with progress
    var transfer_buf: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var downloaded: u64 = 0;
    var last_progress_pct: i64 = -1;
    var read_buf: [32 * 1024]u8 = undefined;

    while (true) {
        const n = reader.readSliceShort(&read_buf) catch |err| {
            logErr("\nError: Read error during download: {}. Try again.\n", .{err});
            out_file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
            return error.NetworkError;
        };
        if (n == 0) break;

        out_file.writeAll(read_buf[0..n]) catch |err| {
            logErr("\nError: Write error: {}. Check disk space.\n", .{err});
            out_file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
            return err;
        };

        downloaded += n;

        // Update progress
        if (content_length) |total| {
            const pct: u64 = downloaded * 100 / total;
            const pct_i: i64 = @intCast(pct);
            if (pct_i != last_progress_pct) {
                last_progress_pct = pct_i;
                const bar_width: u64 = 40;
                const filled: u64 = pct * bar_width / 100;
                const dl_mb = downloaded / (1024 * 1024);
                const total_mb = total / (1024 * 1024);

                // Build progress bar
                var bar: [40]u8 = undefined;
                for (0..bar_width) |i| {
                    if (i < filled) {
                        bar[i] = '=';
                    } else if (i == filled) {
                        bar[i] = '>';
                    } else {
                        bar[i] = ' ';
                    }
                }
                logErr("\r[{s}] {d}% ({d} MB / {d} MB)", .{ &bar, pct, dl_mb, total_mb });
            }
        } else {
            const dl_mb = downloaded / (1024 * 1024);
            logErr("\rDownloaded: {d} MB", .{dl_mb});
        }
    }

    out_file.close();

    // Rename temp file to final path
    std.fs.cwd().rename(tmp_path, path) catch |err| {
        logErr("\nError: Could not rename temp file: {}\n", .{err});
        return err;
    };

    logErr("\nDone. Model saved to {s}\n", .{path});
}

/// Returns the path to the default model (base), used when WHISPER_MODEL not set.
/// Caller must free the returned slice using page_allocator.
pub fn getDefaultModelPath() []const u8 {
    return getModelPath(default_model_name) orelse "models/ggml-base.bin";
}

/// Print CLI usage for model-related arguments.
pub fn printUsage() void {
    const w = std.fs.File.stderr().deprecatedWriter();
    w.print(
        \\Usage: rewright [OPTIONS]
        \\
        \\Options:
        \\  --list-models          List available whisper models
        \\  --download-model NAME  Download a whisper model
        \\  --help                 Show this help message
        \\
        \\Without arguments, starts the normal dictation flow.
        \\
        \\Environment variables:
        \\  WHISPER_MODEL       Path to whisper model file
        \\  WHISPER_LANGUAGE    Language code (e.g. "en", "ja") or "auto"
        \\  LLM_API_URL         OpenAI-compatible API endpoint
        \\  LLM_API_KEY         API key for LLM service
        \\  LLM_MODEL           LLM model name (default: gpt-4o-mini)
        \\  REWRIGHT_VERBOSE    Enable verbose logging (set to any value)
        \\  REWRIGHT_CLIPBOARD  Enable clipboard hook (set to any value)
        \\
    , .{}) catch {};
}

// =========================================================================
// Tests
// =========================================================================

test "findModel returns correct model" {
    const m = findModel("base");
    try std.testing.expect(m != null);
    try std.testing.expectEqualStrings("ggml-base.bin", m.?.filename);
}

test "findModel returns null for unknown" {
    const m = findModel("nonexistent");
    try std.testing.expect(m == null);
}

test "getModelDir returns non-empty string" {
    const dir = getModelDir();
    try std.testing.expect(dir.len > 0);
}

test "getDefaultModelPath returns non-empty string" {
    const path = getDefaultModelPath();
    try std.testing.expect(path.len > 0);
}

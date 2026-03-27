const std = @import("std");
const c = @cImport({
    @cInclude("whisper.h");
});

/// Options for initializing the Whisper context.
pub const WhisperOptions = struct {
    use_gpu: bool = true,
    gpu_device: i32 = 0,
    flash_attn: bool = false,
};

/// Options for a transcription run.
pub const TranscribeOptions = struct {
    language: ?[*:0]const u8 = null,
    n_threads: i32 = 4,
    translate: bool = false,
    single_segment: bool = false,
    no_timestamps: bool = true,
};

/// A single transcribed segment with timing information.
pub const Segment = struct {
    text: []const u8,
    t0: i64,
    t1: i64,
};

/// Result of a transcription run.
pub const TranscriptionResult = struct {
    text: []const u8,
    segments: []const Segment,
};

pub const WhisperError = error{
    ModelNotFound,
    WhisperInitFailed,
    TranscriptionFailed,
};

/// Wrapper around whisper.cpp's C API for model loading, inference, and result extraction.
pub const Whisper = struct {
    ctx: *c.whisper_context,

    // Static buffers for results
    var text_buffer: [32 * 1024]u8 = undefined;
    var segment_buffer: [256]Segment = undefined;

    /// Initialize a Whisper context from a model file.
    /// Returns `error.ModelNotFound` if the file does not exist.
    /// Returns `error.WhisperInitFailed` if whisper_init returns null.
    pub fn init(model_path: [*:0]const u8, opts: WhisperOptions) WhisperError!Whisper {
        // Check if the model file exists
        const path_slice = std.mem.span(model_path);
        std.fs.cwd().access(path_slice, .{}) catch {
            return WhisperError.ModelNotFound;
        };

        var cparams = c.whisper_context_default_params();
        cparams.use_gpu = opts.use_gpu;
        cparams.gpu_device = opts.gpu_device;
        cparams.flash_attn = opts.flash_attn;

        const ctx = c.whisper_init_from_file_with_params(model_path, cparams);
        if (ctx == null) {
            return WhisperError.WhisperInitFailed;
        }

        return Whisper{ .ctx = ctx.? };
    }

    /// Free all resources associated with this Whisper context.
    pub fn deinit(self: Whisper) void {
        c.whisper_free(self.ctx);
    }

    /// Run transcription on PCM f32 audio samples.
    /// Results are stored in static buffers (32K text, 256 segments).
    pub fn transcribe(self: Whisper, samples: []const f32, opts: TranscribeOptions) WhisperError!TranscriptionResult {
        var params = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);

        params.n_threads = opts.n_threads;
        params.translate = opts.translate;
        params.single_segment = opts.single_segment;
        params.no_timestamps = opts.no_timestamps;
        params.language = opts.language;

        // Suppress all printing
        params.print_progress = false;
        params.print_timestamps = false;
        params.print_realtime = false;
        params.print_special = false;

        const n_samples: c_int = @intCast(samples.len);
        const ret = c.whisper_full(self.ctx, params, samples.ptr, n_samples);
        if (ret != 0) {
            return WhisperError.TranscriptionFailed;
        }

        // Extract segments
        const n_segments: usize = @intCast(c.whisper_full_n_segments(self.ctx));
        var text_offset: usize = 0;
        const max_segments = @min(n_segments, segment_buffer.len);

        for (0..max_segments) |i| {
            const seg_idx: c_int = @intCast(i);
            const seg_text_ptr = c.whisper_full_get_segment_text(self.ctx, seg_idx);
            const t0 = c.whisper_full_get_segment_t0(self.ctx, seg_idx);
            const t1 = c.whisper_full_get_segment_t1(self.ctx, seg_idx);

            if (seg_text_ptr == null) {
                segment_buffer[i] = Segment{ .text = &.{}, .t0 = t0, .t1 = t1 };
                continue;
            }
            const seg_text_raw = std.mem.span(seg_text_ptr.?);
            // Copy segment text into the static buffer; skip if buffer full
            const end = text_offset + seg_text_raw.len;
            if (end > text_buffer.len) continue;
            @memcpy(text_buffer[text_offset..end], seg_text_raw);
            const seg_text = text_buffer[text_offset..end];
            text_offset = end;

            segment_buffer[i] = Segment{
                .text = seg_text,
                .t0 = t0,
                .t1 = t1,
            };
        }

        return TranscriptionResult{
            .text = text_buffer[0..text_offset],
            .segments = segment_buffer[0..max_segments],
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const test_model_path: [*:0]const u8 = "models/ggml-tiny.bin";

fn modelExists() bool {
    const path_slice = std.mem.span(test_model_path);
    std.fs.cwd().access(path_slice, .{}) catch return false;
    return true;
}

test "context creation and cleanup" {
    if (!modelExists()) {
        std.log.warn("Skipping test: model file not found at {s}", .{test_model_path});
        return;
    }

    const w = try Whisper.init(test_model_path, .{
        .use_gpu = false,
    });
    defer w.deinit();
}

test "init returns ModelNotFound for missing file" {
    const result = Whisper.init("nonexistent_model.bin", .{});
    try testing.expectError(WhisperError.ModelNotFound, result);
}

test "transcribe silence returns empty or BLANK" {
    if (!modelExists()) {
        std.log.warn("Skipping test: model file not found at {s}", .{test_model_path});
        return;
    }

    const w = try Whisper.init(test_model_path, .{
        .use_gpu = false,
    });
    defer w.deinit();

    // Generate 1 second of silence at 16kHz
    const silence: [16000]f32 = @splat(0.0);

    const result = try w.transcribe(&silence, .{
        .n_threads = 2,
    });

    // Silence should produce either empty text or text containing "[BLANK_AUDIO]"
    const is_empty = result.text.len == 0;
    const contains_blank = std.mem.indexOf(u8, result.text, "BLANK") != null;
    try testing.expect(is_empty or contains_blank);
}

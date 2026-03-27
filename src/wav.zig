const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

pub const WHISPER_SAMPLE_RATE: u32 = 16000;
pub const SILENCE_THRESHOLD: f32 = 0.001;
pub const MAX_SEGMENT_SECONDS: u32 = 15;
pub const MAX_SEGMENT_SAMPLES: u32 = MAX_SEGMENT_SECONDS * WHISPER_SAMPLE_RATE;

// =============================================================================
// Static buffers
// =============================================================================

const MAX_STATIC_SAMPLES: usize = 1_000_000;
const MAX_STATIC_SEGMENTS: usize = 64;

var static_float_buf: [MAX_STATIC_SAMPLES]f32 = undefined;
var static_segments_buf: [MAX_STATIC_SEGMENTS]AudioSegment = undefined;

// =============================================================================
// Types
// =============================================================================

pub const AudioSegment = struct {
    data: []const f32,
    len: usize,
};

// =============================================================================
// Functions
// =============================================================================

/// Convert signed 16-bit PCM samples to float32 in range [-1.0, 1.0].
/// Uses a static buffer; maximum 1,000,000 samples.
/// Asserts that samples.len <= MAX_STATIC_SAMPLES.
pub fn int16ToFloat32(samples: []const i16) []const f32 {
    std.debug.assert(samples.len <= MAX_STATIC_SAMPLES);
    for (samples, 0..) |s, i| {
        static_float_buf[i] = @as(f32, @floatFromInt(s)) / 32768.0;
    }
    return static_float_buf[0..samples.len];
}

/// Convert signed 16-bit PCM samples to float32 in range [-1.0, 1.0].
/// Allocates memory using the given allocator; caller owns the returned slice.
pub fn int16ToFloat32Alloc(allocator: std.mem.Allocator, samples: []const i16) ![]f32 {
    const out = try allocator.alloc(f32, samples.len);
    for (samples, 0..) |s, i| {
        out[i] = @as(f32, @floatFromInt(s)) / 32768.0;
    }
    return out;
}

/// Compute the Root Mean Square of the given float32 samples.
/// Returns 0.0 for empty input.
pub fn calculateRms(samples: []const f32) f32 {
    if (samples.len == 0) return 0.0;
    var sum: f32 = 0.0;
    for (samples) |s| {
        sum += s * s;
    }
    return std.math.sqrt(sum / @as(f32, @floatFromInt(samples.len)));
}

/// Return true when the RMS of samples is below the given threshold.
pub fn isSilent(samples: []const f32, threshold: f32) bool {
    return calculateRms(samples) < threshold;
}

/// Return true when the byte buffer starts with a valid RIFF....WAVE header.
/// Returns false when data.len < 12.
pub fn isWavFormat(data: []const u8) bool {
    if (data.len < 12) return false;
    // Bytes 0-3: "RIFF"
    if (!std.mem.eql(u8, data[0..4], "RIFF")) return false;
    // Bytes 8-11: "WAVE"
    if (!std.mem.eql(u8, data[8..12], "WAVE")) return false;
    return true;
}

/// Split audio samples into segments of at most max_samples each.
/// Uses a static array; at most 64 segments are returned.
/// Asserts that the required number of segments does not exceed 64.
pub fn segmentAudio(samples: []const f32, max_samples: u32) []const AudioSegment {
    if (samples.len == 0 or max_samples == 0) {
        return static_segments_buf[0..0];
    }

    const max: usize = @intCast(max_samples);
    const num_segments = (samples.len + max - 1) / max;
    std.debug.assert(num_segments <= MAX_STATIC_SEGMENTS);

    var idx: usize = 0;
    var offset: usize = 0;
    while (offset < samples.len) : (idx += 1) {
        const end = @min(offset + max, samples.len);
        static_segments_buf[idx] = AudioSegment{
            .data = samples[offset..end],
            .len = end - offset,
        };
        offset = end;
    }

    return static_segments_buf[0..idx];
}

// =============================================================================
// Tests
// =============================================================================

test "int16ToFloat32: zero" {
    const input = [_]i16{0};
    const result = int16ToFloat32(&input);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0], 1e-6);
}

test "int16ToFloat32: positive 16384" {
    const input = [_]i16{16384};
    const result = int16ToFloat32(&input);
    // 16384 / 32768.0 = 0.5
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result[0], 1e-5);
}

test "int16ToFloat32: negative -16384" {
    const input = [_]i16{-16384};
    const result = int16ToFloat32(&input);
    // -16384 / 32768.0 = -0.5
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), result[0], 1e-5);
}

test "int16ToFloat32: max positive 32767" {
    const input = [_]i16{32767};
    const result = int16ToFloat32(&input);
    // 32767 / 32768.0 ≈ 0.999969
    try std.testing.expectApproxEqAbs(@as(f32, 32767.0 / 32768.0), result[0], 1e-5);
}

test "int16ToFloat32: min -32768" {
    const input = [_]i16{-32768};
    const result = int16ToFloat32(&input);
    // -32768 / 32768.0 = -1.0
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), result[0], 1e-5);
}

test "int16ToFloat32Alloc" {
    const allocator = std.testing.allocator;
    const input = [_]i16{ 0, 16384, -16384, 32767, -32768 };
    const result = try int16ToFloat32Alloc(allocator, &input);
    defer allocator.free(result);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), result[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 32767.0 / 32768.0), result[3], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), result[4], 1e-5);
}

test "calculateRms: empty input returns 0.0" {
    const samples: []const f32 = &.{};
    try std.testing.expectEqual(@as(f32, 0.0), calculateRms(samples));
}

test "calculateRms: uniform 0.5 samples" {
    // RMS of all-0.5 array is 0.5
    const samples = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), calculateRms(&samples), 1e-6);
}

test "calculateRms: uniform -0.5 samples" {
    const samples = [_]f32{ -0.5, -0.5, -0.5, -0.5 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), calculateRms(&samples), 1e-6);
}

test "isSilent: below threshold" {
    const samples = [_]f32{ 0.0, 0.0, 0.0 };
    try std.testing.expect(isSilent(&samples, SILENCE_THRESHOLD));
}

test "isSilent: above threshold" {
    const samples = [_]f32{ 0.5, 0.5, 0.5 };
    try std.testing.expect(!isSilent(&samples, SILENCE_THRESHOLD));
}

test "isSilent: exactly at threshold is not silent" {
    // RMS of all-threshold array equals threshold; isSilent checks strictly <
    const t = SILENCE_THRESHOLD;
    const samples = [_]f32{ t, t, t, t };
    try std.testing.expect(!isSilent(&samples, t));
}

test "isWavFormat: valid RIFF/WAVE header" {
    const data = "RIFF\x00\x00\x00\x00WAVEfmt ";
    try std.testing.expect(isWavFormat(data));
}

test "isWavFormat: invalid header" {
    const data = "NOTARIFF....WAVE";
    try std.testing.expect(!isWavFormat(data));
}

test "isWavFormat: too short" {
    const data = "RIFF";
    try std.testing.expect(!isWavFormat(data));
}

test "isWavFormat: exactly 12 bytes with wrong WAVE marker" {
    const data = "RIFF\x00\x00\x00\x00XXXX";
    try std.testing.expect(!isWavFormat(data));
}

test "segmentAudio: 320000 samples -> 2 segments" {
    // Allocate on heap to avoid stack overflow in test
    const allocator = std.testing.allocator;
    const total: usize = 320_000;
    const buf = try allocator.alloc(f32, total);
    defer allocator.free(buf);
    for (buf) |*s| s.* = 0.1;

    const max: u32 = 240_000;
    const segments = segmentAudio(buf, max);

    try std.testing.expectEqual(@as(usize, 2), segments.len);
    try std.testing.expectEqual(@as(usize, 240_000), segments[0].len);
    try std.testing.expectEqual(@as(usize, 80_000), segments[1].len);
}

test "segmentAudio: samples fit exactly in one segment" {
    const samples = [_]f32{ 0.1, 0.2, 0.3 };
    const segments = segmentAudio(&samples, 10);
    try std.testing.expectEqual(@as(usize, 1), segments.len);
    try std.testing.expectEqual(@as(usize, 3), segments[0].len);
}

test "segmentAudio: empty input" {
    const samples: []const f32 = &.{};
    const segments = segmentAudio(samples, 100);
    try std.testing.expectEqual(@as(usize, 0), segments.len);
}

test "constants are correct" {
    try std.testing.expectEqual(@as(u32, 16000), WHISPER_SAMPLE_RATE);
    try std.testing.expectApproxEqAbs(@as(f32, 0.001), SILENCE_THRESHOLD, 1e-9);
    try std.testing.expectEqual(@as(u32, 15), MAX_SEGMENT_SECONDS);
    try std.testing.expectEqual(@as(u32, 240_000), MAX_SEGMENT_SAMPLES);
}

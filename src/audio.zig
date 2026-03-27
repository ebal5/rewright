const std = @import("std");
const c = @cImport({
    @cDefine("MA_NO_DECODING", "");
    @cDefine("MA_NO_ENCODING", "");
    @cDefine("MA_NO_GENERATION", "");
    @cInclude("miniaudio.h");
});

// Static buffer: 30 seconds at 16kHz mono = 480,000 samples
const BUFFER_SIZE = 30 * 16000;
var static_buffer: [BUFFER_SIZE]f32 = undefined;

pub const AudioCaptureConfig = struct {
    sample_rate: u32 = 16000,
    channels: u32 = 1,
    max_duration_seconds: u32 = 30,
};

pub const AudioCapture = struct {
    device: c.ma_device,
    config: AudioCaptureConfig,
    buffer: []f32,
    write_pos: std.atomic.Value(usize),
    is_recording: std.atomic.Value(bool),

    /// Initialize audio capture. Must be called on a stable pointer (not a temporary).
    /// Usage: `var audio = AudioCapture.create(cfg); try audio.initDevice();`
    pub fn create(cfg: AudioCaptureConfig) AudioCapture {
        return .{
            .device = undefined,
            .config = cfg,
            .buffer = static_buffer[0 .. cfg.max_duration_seconds * cfg.sample_rate],
            .write_pos = std.atomic.Value(usize).init(0),
            .is_recording = std.atomic.Value(bool).init(false),
        };
    }

    /// Initialize the audio device. Must be called after the AudioCapture has a stable address.
    pub fn initDevice(self: *AudioCapture) !void {
        var device_config = c.ma_device_config_init(c.ma_device_type_capture);
        device_config.capture.format = c.ma_format_f32;
        device_config.capture.channels = @intCast(self.config.channels);
        device_config.sampleRate = @intCast(self.config.sample_rate);
        device_config.dataCallback = dataCallback;
        device_config.pUserData = self; // stable pointer — self is already at its final address

        const result = c.ma_device_init(null, &device_config, &self.device);
        if (result != c.MA_SUCCESS) {
            return error.AudioDeviceInitFailed;
        }
    }

    pub fn deinit(self: *AudioCapture) void {
        c.ma_device_uninit(&self.device);
    }

    pub fn startRecording(self: *AudioCapture) !void {
        self.write_pos.store(0, .seq_cst);

        const result = c.ma_device_start(&self.device);
        if (result != c.MA_SUCCESS) {
            return error.AudioStartFailed;
        }
        // Set recording flag after device starts successfully
        self.is_recording.store(true, .seq_cst);
    }

    pub fn stopRecording(self: *AudioCapture) []const f32 {
        self.is_recording.store(false, .seq_cst);
        _ = c.ma_device_stop(&self.device);

        const pos = self.write_pos.load(.seq_cst);
        return self.buffer[0..pos];
    }

    pub fn isRecording(self: *AudioCapture) bool {
        return self.is_recording.load(.seq_cst);
    }
};

fn dataCallback(
    pDevice: ?*c.ma_device,
    _pOutput: ?*anyopaque,
    pInput: ?*const anyopaque,
    frameCount: c.ma_uint32,
) callconv(.c) void {
    _ = _pOutput;

    const device = pDevice orelse return;
    const capture: *AudioCapture = @ptrCast(@alignCast(device.*.pUserData orelse return));

    if (!capture.is_recording.load(.acquire)) return;

    const input_ptr = pInput orelse return;
    const input_samples: [*]const f32 = @ptrCast(@alignCast(input_ptr));

    const current_pos = capture.write_pos.load(.acquire);
    const buffer_len = capture.buffer.len;
    const remaining = buffer_len - current_pos;
    const n_frames: usize = @intCast(frameCount);
    const samples_to_copy = @min(n_frames, remaining);

    if (samples_to_copy == 0) {
        // Buffer full — stop recording
        capture.is_recording.store(false, .release);
        return;
    }

    @memcpy(capture.buffer[current_pos .. current_pos + samples_to_copy], input_samples[0..samples_to_copy]);
    capture.write_pos.store(current_pos + samples_to_copy, .release);
}

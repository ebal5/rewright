const std = @import("std");
const AudioCapture = @import("audio").AudioCapture;
const Whisper = @import("whisper").Whisper;
const WhisperError = @import("whisper").WhisperError;
const wav_util = @import("wav");
const hook_mod = @import("hook");
const StdoutHook = @import("stdout_hook").StdoutHook;
const LlmHook = @import("llm_hook").LlmHook;
const LlmConfig = @import("llm_hook").LlmConfig;
const ClipboardHook = @import("clipboard_hook").ClipboardHook;
const model_manager = @import("model_manager");

const c_env = @cImport({
    @cInclude("stdlib.h");
});

fn getEnv(key: [*:0]const u8) ?[:0]const u8 {
    const val = c_env.getenv(key) orelse return null;
    return std.mem.span(val);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    const w = std.fs.File.stderr().deprecatedWriter();
    w.print(fmt, args) catch {};
}

pub fn main() !void {
    // =========================================================================
    // Parse CLI arguments
    // =========================================================================
    const allocator = std.heap.page_allocator;
    const args = std.process.argsAlloc(allocator) catch {
        log("Error: Failed to parse command line arguments.\n", .{});
        std.process.exit(1);
    };
    defer std.process.argsFree(allocator, args);

    var i: usize = 1; // skip argv[0]
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            model_manager.printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--list-models")) {
            model_manager.listModels();
            return;
        } else if (std.mem.eql(u8, arg, "--download-model")) {
            i += 1;
            if (i >= args.len) {
                log("Error: --download-model requires a model name argument.\n", .{});
                log("Run with --list-models to see available models.\n", .{});
                std.process.exit(1);
            }
            model_manager.downloadModel(args[i]) catch {
                std.process.exit(1);
            };
            return;
        } else {
            log("Error: Unknown argument '{s}'\n", .{arg});
            model_manager.printUsage();
            std.process.exit(1);
        }
    }

    // =========================================================================
    // Parse configuration from environment variables
    // =========================================================================
    const model_path_env = getEnv("WHISPER_MODEL");
    const default_model_path = model_manager.getDefaultModelPath();
    const model_path_slice: []const u8 = if (model_path_env) |e| e else default_model_path;
    // For Whisper.init we need a sentinel-terminated pointer.
    // getenv returns [:0]const u8 (already sentinel-terminated).
    // For the default path, we need to create a sentinel-terminated copy.
    const model_path: [*:0]const u8 = if (model_path_env) |e| e.ptr else blk: {
        const buf = allocator.allocSentinel(u8, default_model_path.len, 0) catch {
            log("Error: Out of memory.\n", .{});
            std.process.exit(1);
        };
        @memcpy(buf, default_model_path);
        break :blk buf.ptr;
    };

    const language_env = getEnv("WHISPER_LANGUAGE");
    const language: ?[*:0]const u8 = if (language_env) |l| l.ptr else null;

    const llm_api_url: []const u8 = if (getEnv("LLM_API_URL")) |e| e else "https://api.openai.com/v1/chat/completions";
    const llm_api_key = getEnv("LLM_API_KEY");
    const llm_model: []const u8 = if (getEnv("LLM_MODEL")) |e| e else "gpt-4o-mini";
    const verbose = getEnv("REWRIGHT_VERBOSE") != null;
    const clipboard_enabled = getEnv("REWRIGHT_CLIPBOARD") != null;

    if (verbose) {
        log("[config] model={s}\n", .{model_path_slice});
        log("[config] language={s}\n", .{if (language_env) |l| @as([]const u8, l) else "auto"});
        log("[config] llm_url={s}\n", .{llm_api_url});
        log("[config] llm_model={s}\n", .{llm_model});
        log("[config] llm_enabled={}\n", .{llm_api_key != null});
        log("[config] clipboard={}\n", .{clipboard_enabled});
    }

    // =========================================================================
    // Initialize Whisper
    // =========================================================================
    log("Loading whisper model: {s}\n", .{model_path_slice});

    const whisper_ctx = Whisper.init(model_path, .{ .use_gpu = true }) catch |err| {
        switch (err) {
            WhisperError.ModelNotFound => {
                log(
                    \\Error: Whisper model not found at '{s}'
                    \\
                    \\To download a model, run:
                    \\  mkdir -p models
                    \\  curl -L -o models/ggml-base.bin \
                    \\    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
                    \\
                , .{model_path_slice});
                std.process.exit(1);
            },
            WhisperError.WhisperInitFailed => {
                log("Error: Failed to initialize whisper context. The model file may be corrupted.\n", .{});
                std.process.exit(1);
            },
            else => {
                log("Error: Unexpected error initializing whisper: {}\n", .{err});
                std.process.exit(1);
            },
        }
    };
    defer whisper_ctx.deinit();

    log("Whisper model loaded successfully.\n", .{});

    // =========================================================================
    // Initialize Audio
    // =========================================================================
    var audio = AudioCapture.create(.{
        .sample_rate = wav_util.WHISPER_SAMPLE_RATE,
        .channels = 1,
        .max_duration_seconds = 30,
    });
    audio.initDevice() catch {
        log("Error: Failed to initialize audio capture device.\n", .{});
        std.process.exit(1);
    };
    defer audio.deinit();

    log("Audio device initialized.\n", .{});

    // =========================================================================
    // Set up hooks
    // =========================================================================
    var dispatcher = hook_mod.HookDispatcher{};

    // Always register stdout hook
    var stdout_hook = StdoutHook{ .verbose = verbose };
    dispatcher.register(stdout_hook.hookImpl());

    // Register LLM hook if API key is set
    var llm_hook: LlmHook = undefined;
    if (llm_api_key) |key| {
        llm_hook = LlmHook{
            .config = LlmConfig{
                .api_url = llm_api_url,
                .api_key = key,
                .model = llm_model,
                .system_prompt = "You are a helpful assistant that cleans up speech-to-text transcriptions. Fix grammar, punctuation, and formatting while preserving the original meaning.",
            },
        };
        dispatcher.register(llm_hook.hookImpl());
        log("LLM hook enabled (model: {s}).\n", .{llm_model});
    }

    // Register ClipboardHook if REWRIGHT_CLIPBOARD is set
    var clipboard_hook: ClipboardHook = undefined;
    if (clipboard_enabled) {
        clipboard_hook = ClipboardHook{};
        dispatcher.register(clipboard_hook.hookImpl());
        log("Clipboard hook enabled.\n", .{});
    }

    // =========================================================================
    // Main loop
    // =========================================================================
    const stdin = std.fs.File.stdin().deprecatedReader();

    log("\nReady. Press Enter to start recording, Enter again to stop. Ctrl+C to quit.\n", .{});

    while (true) {
        // Wait for Enter to start recording
        log("\n[Press Enter to start recording]\n", .{});
        _ = stdin.readByte() catch |err| {
            switch (err) {
                error.EndOfStream => {
                    log("\nEOF received. Exiting.\n", .{});
                    return;
                },
                else => {
                    log("\nInput error: {}. Exiting.\n", .{err});
                    return;
                },
            }
        };

        // Start recording
        audio.startRecording() catch {
            log("Error: Failed to start recording.\n", .{});
            continue;
        };
        log("Recording... [Press Enter to stop]\n", .{});

        // Wait for Enter to stop recording
        _ = stdin.readByte() catch |err| {
            switch (err) {
                error.EndOfStream => {
                    _ = audio.stopRecording();
                    log("\nEOF received. Exiting.\n", .{});
                    return;
                },
                else => {
                    _ = audio.stopRecording();
                    log("\nInput error: {}. Exiting.\n", .{err});
                    return;
                },
            }
        };

        // Stop recording and get samples
        const samples = audio.stopRecording();

        if (samples.len == 0) {
            log("No audio captured. Try again.\n", .{});
            continue;
        }

        if (verbose) {
            const duration_s = @as(f32, @floatFromInt(samples.len)) / @as(f32, @floatFromInt(wav_util.WHISPER_SAMPLE_RATE));
            log("[audio] captured {d} samples ({d:.1}s)\n", .{ samples.len, duration_s });
        }

        // Check for silence
        if (wav_util.isSilent(samples, wav_util.SILENCE_THRESHOLD)) {
            log("(silence detected, skipping transcription)\n", .{});
            continue;
        }

        // Transcribe
        log("Transcribing...\n", .{});

        const result = whisper_ctx.transcribe(samples, .{
            .language = language,
            .n_threads = 4,
        }) catch |err| {
            log("Transcription error: {}\n", .{err});
            continue;
        };

        if (result.text.len == 0) {
            log("(empty transcription, skipping)\n", .{});
            continue;
        }

        // Dispatch to hooks
        dispatcher.dispatch(&result) catch |err| {
            log("Hook dispatch error: {}\n", .{err});
        };
    }
}

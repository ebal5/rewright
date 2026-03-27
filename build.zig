const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =================================================================
    // GPU Backend Options
    // =================================================================
    //
    // CUDA (-Dcuda=true):
    //   Enables GGML_USE_CUDA macro and links CUDA system libraries.
    //   Requires CUDA Toolkit to be installed (nvcc, libcuda, libcublas, libcudart).
    //   NOTE: The CUDA source files (.cu) require nvcc to compile, which Zig
    //   cannot invoke directly. For full CUDA support, pre-build whisper.cpp
    //   with CMake and link the resulting libraries, or use a custom build
    //   script that invokes nvcc separately.
    //   This option adds the macro and library links as the foundation.
    //
    // Vulkan (-Dvulkan=true):
    //   Enables GGML_USE_VULKAN macro and links the Vulkan system library.
    //   NOTE: Full Vulkan support requires GLSL shader compilation to SPIR-V,
    //   which is complex in Zig's build system. For full Vulkan support,
    //   pre-build whisper.cpp with CMake (which handles shader compilation
    //   via glslc/glslangValidator). This option adds the macro and library
    //   link as the foundation; shader compilation must be done separately.
    //
    const enable_cuda = b.option(bool, "cuda", "Enable CUDA GPU backend (requires CUDA Toolkit)") orelse false;
    const enable_vulkan = b.option(bool, "vulkan", "Enable Vulkan GPU backend (requires Vulkan SDK; shader compilation must be done separately)") orelse false;

    // --- Paths ---
    const ggml_src = b.path("libs/whisper.cpp/ggml/src");
    const ggml_include = b.path("libs/whisper.cpp/ggml/include");
    const whisper_include = b.path("libs/whisper.cpp/include");
    const whisper_src = b.path("libs/whisper.cpp/src");
    const miniaudio_dir = b.path("libs/miniaudio");
    const ggml_cpu_dir = b.path("libs/whisper.cpp/ggml/src/ggml-cpu");

    // Common C/C++ flags
    const common_c_flags: []const []const u8 = &.{
        "-DGGML_USE_CPU",
        "-D_GNU_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DNDEBUG",
        "-DGGML_VERSION=\"0.9.8\"",
        "-DGGML_COMMIT=\"v1.8.4\"",
    };

    const common_cpp_flags: []const []const u8 = &.{
        "-DGGML_USE_CPU",
        "-D_GNU_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DNDEBUG",
        "-DGGML_VERSION=\"0.9.8\"",
        "-DGGML_COMMIT=\"v1.8.4\"",
        "-std=c++17",
    };

    const whisper_cpp_flags: []const []const u8 = &.{
        "-DGGML_USE_CPU",
        "-D_GNU_SOURCE",
        "-D_XOPEN_SOURCE=600",
        "-DNDEBUG",
        "-DGGML_VERSION=\"0.9.8\"",
        "-DGGML_COMMIT=\"v1.8.4\"",
        "-DWHISPER_VERSION=\"1.8.4\"",
        "-std=c++17",
    };

    // Build GPU macro flags (appended to the base flags at usage sites).
    // Zig 0.15 ArrayList API: initialize with .empty and pass allocator per call.
    var gpu_c_flags: std.ArrayList([]const u8) = .empty;
    var gpu_cpp_flags: std.ArrayList([]const u8) = .empty;
    var gpu_whisper_flags: std.ArrayList([]const u8) = .empty;

    // Start with the base flags
    gpu_c_flags.appendSlice(b.allocator, common_c_flags) catch @panic("OOM");
    gpu_cpp_flags.appendSlice(b.allocator, common_cpp_flags) catch @panic("OOM");
    gpu_whisper_flags.appendSlice(b.allocator, whisper_cpp_flags) catch @panic("OOM");

    if (enable_cuda) {
        gpu_c_flags.append(b.allocator, "-DGGML_USE_CUDA") catch @panic("OOM");
        gpu_cpp_flags.append(b.allocator, "-DGGML_USE_CUDA") catch @panic("OOM");
        gpu_whisper_flags.append(b.allocator, "-DGGML_USE_CUDA") catch @panic("OOM");
    }
    if (enable_vulkan) {
        gpu_c_flags.append(b.allocator, "-DGGML_USE_VULKAN") catch @panic("OOM");
        gpu_cpp_flags.append(b.allocator, "-DGGML_USE_VULKAN") catch @panic("OOM");
        gpu_whisper_flags.append(b.allocator, "-DGGML_USE_VULKAN") catch @panic("OOM");
    }

    const eff_c_flags = gpu_c_flags.items;
    const eff_cpp_flags = gpu_cpp_flags.items;
    const eff_whisper_flags = gpu_whisper_flags.items;

    // =================================================================
    // ggml-base: core ggml library
    // =================================================================
    const ggml_base = b.addLibrary(.{
        .linkage = .static,
        .name = "ggml-base",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
    });

    ggml_base.addCSourceFiles(.{
        .root = ggml_src,
        .files = &.{
            "ggml.c",
            "ggml-alloc.c",
            "ggml-quants.c",
        },
        .flags = eff_c_flags,
    });

    ggml_base.addCSourceFiles(.{
        .root = ggml_src,
        .files = &.{
            "ggml.cpp",
            "ggml-backend.cpp",
            "ggml-opt.cpp",
            "ggml-threading.cpp",
            "gguf.cpp",
        },
        .flags = eff_cpp_flags,
    });

    ggml_base.addIncludePath(ggml_include);
    ggml_base.addIncludePath(ggml_src);

    // =================================================================
    // ggml (backend registry)
    // =================================================================
    const ggml_reg = b.addLibrary(.{
        .linkage = .static,
        .name = "ggml",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
    });

    ggml_reg.addCSourceFiles(.{
        .root = ggml_src,
        .files = &.{
            "ggml-backend-reg.cpp",
            "ggml-backend-dl.cpp",
        },
        .flags = eff_cpp_flags,
    });

    ggml_reg.addIncludePath(ggml_include);
    ggml_reg.addIncludePath(ggml_src);

    // =================================================================
    // ggml-cpu: CPU backend
    // =================================================================
    const ggml_cpu = b.addLibrary(.{
        .linkage = .static,
        .name = "ggml-cpu",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
    });

    ggml_cpu.addCSourceFiles(.{
        .root = ggml_src,
        .files = &.{
            "ggml-cpu/ggml-cpu.c",
            "ggml-cpu/quants.c",
            "ggml-cpu/arch/x86/quants.c",
        },
        .flags = eff_c_flags,
    });

    ggml_cpu.addCSourceFiles(.{
        .root = ggml_src,
        .files = &.{
            "ggml-cpu/ggml-cpu.cpp",
            "ggml-cpu/repack.cpp",
            "ggml-cpu/hbm.cpp",
            "ggml-cpu/traits.cpp",
            "ggml-cpu/amx/amx.cpp",
            "ggml-cpu/amx/mmq.cpp",
            "ggml-cpu/binary-ops.cpp",
            "ggml-cpu/unary-ops.cpp",
            "ggml-cpu/vec.cpp",
            "ggml-cpu/ops.cpp",
            "ggml-cpu/arch/x86/repack.cpp",
            "ggml-cpu/llamafile/sgemm.cpp",
        },
        .flags = eff_cpp_flags,
    });

    ggml_cpu.addIncludePath(ggml_include);
    ggml_cpu.addIncludePath(ggml_src);
    ggml_cpu.addIncludePath(ggml_cpu_dir);

    // =================================================================
    // whisper: whisper.cpp library
    // =================================================================
    const whisper = b.addLibrary(.{
        .linkage = .static,
        .name = "whisper",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
    });

    whisper.addCSourceFiles(.{
        .root = whisper_src,
        .files = &.{
            "whisper.cpp",
        },
        .flags = eff_whisper_flags,
    });

    whisper.addIncludePath(whisper_include);
    whisper.addIncludePath(whisper_src);
    whisper.addIncludePath(ggml_include);
    whisper.addIncludePath(ggml_src);

    // =================================================================
    // Shared Zig modules (used by both exe and tests)
    // =================================================================
    const whisper_mod = b.createModule(.{
        .root_source_file = b.path("src/whisper.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    whisper_mod.addIncludePath(whisper_include);
    whisper_mod.addIncludePath(ggml_include);

    const hook_mod = b.createModule(.{
        .root_source_file = b.path("src/hook.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    hook_mod.addIncludePath(whisper_include);
    hook_mod.addIncludePath(ggml_include);
    hook_mod.addImport("whisper", whisper_mod);

    const wav_mod = b.createModule(.{
        .root_source_file = b.path("src/wav.zig"),
        .target = target,
        .optimize = optimize,
    });

    const audio_mod = b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    audio_mod.addIncludePath(miniaudio_dir);

    const stdout_hook_mod = b.createModule(.{
        .root_source_file = b.path("src/hooks/stdout_hook.zig"),
        .target = target,
        .optimize = optimize,
    });
    stdout_hook_mod.addImport("hook", hook_mod);

    const llm_hook_mod = b.createModule(.{
        .root_source_file = b.path("src/hooks/llm_hook.zig"),
        .target = target,
        .optimize = optimize,
    });
    llm_hook_mod.addImport("hook", hook_mod);

    const clipboard_hook_mod = b.createModule(.{
        .root_source_file = b.path("src/hooks/clipboard_hook.zig"),
        .target = target,
        .optimize = optimize,
    });
    clipboard_hook_mod.addImport("hook", hook_mod);

    const model_manager_mod = b.createModule(.{
        .root_source_file = b.path("src/model_manager.zig"),
        .target = target,
        .optimize = optimize,
    });

    // =================================================================
    // Main executable
    // =================================================================
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    exe_mod.addImport("audio", audio_mod);
    exe_mod.addImport("whisper", whisper_mod);
    exe_mod.addImport("wav", wav_mod);
    exe_mod.addImport("hook", hook_mod);
    exe_mod.addImport("stdout_hook", stdout_hook_mod);
    exe_mod.addImport("llm_hook", llm_hook_mod);
    exe_mod.addImport("clipboard_hook", clipboard_hook_mod);
    exe_mod.addImport("model_manager", model_manager_mod);

    const exe = b.addExecutable(.{
        .name = "rewright",
        .root_module = exe_mod,
    });

    // Add miniaudio
    exe.addCSourceFiles(.{
        .root = miniaudio_dir,
        .files = &.{
            "miniaudio_impl.c",
        },
        .flags = &.{
            "-DMA_NO_ENCODING",
            "-DMA_NO_GENERATION",
            "-DNDEBUG",
        },
    });

    // Include paths for @cImport
    exe.addIncludePath(whisper_include);
    exe.addIncludePath(ggml_include);
    exe.addIncludePath(miniaudio_dir);

    // Link all our static libraries
    exe.linkLibrary(ggml_base);
    exe.linkLibrary(ggml_reg);
    exe.linkLibrary(ggml_cpu);
    exe.linkLibrary(whisper);

    // Platform libraries
    const target_info = target.result;
    if (target_info.os.tag == .windows) {
        exe.linkSystemLibrary("ole32");
        exe.linkSystemLibrary("winmm");
    } else {
        exe.linkSystemLibrary("pthread");
        exe.linkSystemLibrary("m");
        exe.linkSystemLibrary("dl");
    }

    // GPU backend libraries
    // CUDA: links the three required CUDA runtime libraries.
    // NOTE: .cu source files require nvcc and cannot be compiled by Zig directly.
    //       For full CUDA support, compile ggml-cuda sources with nvcc separately
    //       and link the resulting object/library, or pre-build whisper.cpp with CMake.
    if (enable_cuda) {
        exe.linkSystemLibrary("cuda");
        exe.linkSystemLibrary("cublas");
        exe.linkSystemLibrary("cudart");
        // Also apply to ggml libraries so the macro is active during compilation
        ggml_base.linkSystemLibrary("cuda");
        ggml_reg.linkSystemLibrary("cuda");
    }

    // Vulkan: links the Vulkan loader.
    // NOTE: Full Vulkan support requires GLSL shaders pre-compiled to SPIR-V.
    //       Compile shaders with: glslc or glslangValidator on the .comp files in
    //       libs/whisper.cpp/ggml/src/ggml-vulkan/vulkan-shaders/
    //       Or pre-build whisper.cpp with CMake (cmake -DGGML_VULKAN=ON ...).
    if (enable_vulkan) {
        exe.linkSystemLibrary("vulkan");
        ggml_base.linkSystemLibrary("vulkan");
        ggml_reg.linkSystemLibrary("vulkan");
    }

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run rewright");
    run_step.dependOn(&run_cmd.step);

    // Test step
    const test_step = b.step("test", "Run unit tests");

    // WAV utilities tests
    const wav_tests = b.addTest(.{
        .root_module = wav_mod,
    });
    const run_wav_tests = b.addRunArtifact(wav_tests);
    test_step.dependOn(&run_wav_tests.step);

    // tests/test_wav.zig (thin wrapper using the wav module)
    const test_wav_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_wav.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_wav_mod.addImport("wav", wav_mod);
    const test_wav = b.addTest(.{
        .root_module = test_wav_mod,
    });
    const run_test_wav = b.addRunArtifact(test_wav);
    test_step.dependOn(&run_test_wav.step);

    // Whisper C API wrapper tests
    const whisper_tests = b.addTest(.{
        .root_module = whisper_mod,
    });
    whisper_tests.linkLibrary(ggml_base);
    whisper_tests.linkLibrary(ggml_reg);
    whisper_tests.linkLibrary(ggml_cpu);
    whisper_tests.linkLibrary(whisper);

    // Platform libraries needed for whisper.cpp
    if (target_info.os.tag == .windows) {
        whisper_tests.linkSystemLibrary("ole32");
        whisper_tests.linkSystemLibrary("winmm");
    } else {
        whisper_tests.linkSystemLibrary("pthread");
        whisper_tests.linkSystemLibrary("m");
        whisper_tests.linkSystemLibrary("dl");
    }

    // GPU backend libraries for tests
    if (enable_cuda) {
        whisper_tests.linkSystemLibrary("cuda");
        whisper_tests.linkSystemLibrary("cublas");
        whisper_tests.linkSystemLibrary("cudart");
    }
    if (enable_vulkan) {
        whisper_tests.linkSystemLibrary("vulkan");
    }

    const run_whisper_tests = b.addRunArtifact(whisper_tests);
    test_step.dependOn(&run_whisper_tests.step);

    // Hook system tests
    const test_hook_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_hook.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_hook_mod.addImport("hook", hook_mod);

    const test_hook = b.addTest(.{
        .root_module = test_hook_mod,
    });
    const run_test_hook = b.addRunArtifact(test_hook);
    test_step.dependOn(&run_test_hook.step);

    // LLM hook tests
    const test_llm_hook_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_llm_hook.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_llm_hook_mod.addImport("llm_hook", llm_hook_mod);

    const test_llm_hook = b.addTest(.{
        .root_module = test_llm_hook_mod,
    });
    const run_test_llm_hook = b.addRunArtifact(test_llm_hook);
    test_step.dependOn(&run_test_llm_hook.step);

    // Model manager tests
    const model_manager_tests = b.addTest(.{
        .root_module = model_manager_mod,
    });
    const run_model_manager_tests = b.addRunArtifact(model_manager_tests);
    test_step.dependOn(&run_model_manager_tests.step);
}

// tests/test_wav.zig
//
// Standalone test file for wav.zig.
// Run via `zig build test` (uses the test step in build.zig).
//
// All test logic lives in src/wav.zig as inline `test` blocks (Zig convention).
// This file re-exports the module so its tests are picked up by the test runner.

const wav = @import("wav");

// Reference the module so it is included in the test binary.
// The inline tests inside wav.zig are run automatically.
comptime {
    _ = wav;
}

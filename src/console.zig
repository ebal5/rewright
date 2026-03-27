const std = @import("std");
const builtin = @import("builtin");

const win32 = if (builtin.os.tag == .windows) @cImport({
    @cInclude("windows.h");
}) else undefined;

/// Code page constant for UTF-8. Defined locally in case @cImport
/// does not expose the CP_UTF8 macro.
const CP_UTF8: c_uint = 65001;

pub const ConsoleWriter = struct {
    file: std.fs.File,
    is_console: bool, // true if real console (not pipe/redirect)

    pub fn print(self: ConsoleWriter, comptime fmt: []const u8, args: anytype) void {
        // Format to stack buffer, then writeAll
        var buf: [8192]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => {
                // Buffer too small, write what we can
                self.writeAll(&buf);
                return;
            },
        };
        self.writeAll(text);
    }

    pub fn writeAll(self: ConsoleWriter, bytes: []const u8) void {
        if (builtin.os.tag == .windows and self.is_console) {
            writeConsoleW(self.file, bytes);
        } else {
            self.file.writeAll(bytes) catch {};
        }
    }
};

fn writeConsoleW(file: std.fs.File, utf8: []const u8) void {
    if (builtin.os.tag != .windows) return;

    // On Windows, std.fs.File.handle is std.os.windows.HANDLE (*anyopaque).
    // win32.HANDLE from @cImport is ?*anyopaque. Use @ptrCast for the conversion.
    const handle: win32.HANDLE = @ptrCast(file.handle);

    // Convert UTF-8 to UTF-16LE
    var wbuf: [4096]win32.WCHAR = undefined;
    const wlen = win32.MultiByteToWideChar(
        CP_UTF8,
        0,
        @ptrCast(utf8.ptr),
        @intCast(utf8.len),
        &wbuf,
        wbuf.len,
    );
    if (wlen <= 0) return;

    var written: win32.DWORD = 0;
    _ = win32.WriteConsoleW(handle, &wbuf, @intCast(wlen), &written, null);
}

pub fn stderr() ConsoleWriter {
    const file = std.fs.File.stderr();
    return .{
        .file = file,
        .is_console = isConsole(file),
    };
}

pub fn stdout() ConsoleWriter {
    const file = std.fs.File.stdout();
    return .{
        .file = file,
        .is_console = isConsole(file),
    };
}

fn isConsole(file: std.fs.File) bool {
    if (builtin.os.tag != .windows) return false;
    var mode: win32.DWORD = 0;
    const handle: win32.HANDLE = @ptrCast(file.handle);
    return win32.GetConsoleMode(handle, &mode) != 0;
}

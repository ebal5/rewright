const std = @import("std");
const builtin = @import("builtin");
const Tray = @import("tray").Tray;
const messages = @import("messages");
const console = @import("console");

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "");
    @cInclude("windows.h");
});

var g_tray: ?Tray = null;

fn log(comptime fmt: []const u8, args: anytype) void {
    console.stderr().print(fmt, args);
}

pub fn run() void {
    log("Starting GUI mode...\n", .{});

    const hInstance: win.HINSTANCE = @ptrCast(win.GetModuleHandleW(null));

    // Register window class
    var wc: win.WNDCLASSEXW = std.mem.zeroes(win.WNDCLASSEXW);
    wc.cbSize = @sizeOf(win.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = toUtf16("RewrightWindowClass");

    if (win.RegisterClassExW(&wc) == 0) {
        log("Error: Failed to register window class.\n", .{});
        return;
    }

    // Create a hidden message-only window
    const hwnd = win.CreateWindowExW(
        0, // dwExStyle
        toUtf16("RewrightWindowClass"),
        toUtf16("rewright"),
        0, // dwStyle (hidden)
        0,
        0,
        0,
        0,
        null,
        null,
        hInstance,
        null,
    );

    if (hwnd == null) {
        log("Error: Failed to create window.\n", .{});
        return;
    }

    // Initialize system tray
    g_tray = Tray.init(@ptrCast(hwnd.?));
    log("System tray icon created.\n", .{});

    // Message loop
    var msg: win.MSG = undefined;
    while (win.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageW(&msg);
    }

    // Cleanup
    if (g_tray) |*tray| {
        tray.deinit();
    }
    log("GUI mode exited.\n", .{});
}

fn wndProc(hwnd: win.HWND, uMsg: c_uint, wParam: win.WPARAM, lParam: win.LPARAM) callconv(.c) win.LRESULT {
    switch (uMsg) {
        win.WM_COMMAND => {
            const id: c_uint = @truncate(wParam);
            if (Tray.handleMenuCommand(id)) return 0;
        },
        messages.WM_APP_TRAY_CALLBACK => {
            const event: c_uint = @truncate(@as(c_ulonglong, @bitCast(lParam)));
            switch (event) {
                win.WM_RBUTTONUP => {
                    if (g_tray) |*tray| {
                        tray.showContextMenu(@ptrCast(hwnd.?));
                    }
                },
                win.WM_LBUTTONDBLCLK => {
                    // Future: toggle overlay or show settings
                },
                else => {},
            }
            return 0;
        },
        win.WM_DESTROY => {
            win.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return win.DefWindowProcW(hwnd, uMsg, wParam, lParam);
}

/// Convert a comptime ASCII string to a null-terminated UTF-16 (WCHAR) pointer.
fn toUtf16(comptime s: []const u8) [*:0]const win.WCHAR {
    const data = comptime blk: {
        var buf: [s.len:0]win.WCHAR = undefined;
        for (s, 0..) |ch, idx| {
            buf[idx] = ch;
        }
        break :blk buf;
    };
    return &data;
}

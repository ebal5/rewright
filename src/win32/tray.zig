const std = @import("std");
const messages = @import("messages");

const win = @cImport({
    @cInclude("windows.h");
    @cInclude("shellapi.h");
});

const NIF_MESSAGE = 0x00000001;
const NIF_ICON = 0x00000002;
const NIF_TIP = 0x00000004;
const NIM_ADD = 0x00000000;
const NIM_DELETE = 0x00000002;

// Context menu item IDs
pub const IDM_SETTINGS: c_uint = 1000;
const IDM_QUIT: c_uint = 1001;

/// Convert a raw handle (usize) to win.HWND without alignment checks.
/// HWND is an opaque kernel handle, not a real pointer to struct_HWND__,
/// so its value may not satisfy the alignment that Zig's @ptrFromInt
/// enforces. We reinterpret the bits via a same-sized stack slot instead.
fn hwndFromInt(raw: usize) win.HWND {
    var val = raw;
    return @as(*const win.HWND, @ptrCast(&val)).*;
}

pub const Tray = struct {
    nid: win.NOTIFYICONDATAW,

    pub fn init(hwnd_raw: usize) Tray {
        const hwnd: win.HWND = hwndFromInt(hwnd_raw);
        var nid: win.NOTIFYICONDATAW = std.mem.zeroes(win.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(win.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = 1;
        nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        nid.uCallbackMessage = messages.WM_APP_TRAY_CALLBACK;
        nid.hIcon = win.LoadIconW(null, @ptrFromInt(@as(usize, 32512))); // IDI_APPLICATION
        copyTip(&nid.szTip, "rewright");

        _ = win.Shell_NotifyIconW(NIM_ADD, &nid);

        return .{ .nid = nid };
    }

    pub fn deinit(self: *Tray) void {
        _ = win.Shell_NotifyIconW(NIM_DELETE, &self.nid);
    }

    pub fn showContextMenu(self: *const Tray, hwnd_raw: usize) void {
        _ = self;
        const hwnd: win.HWND = hwndFromInt(hwnd_raw);

        const menu = win.CreatePopupMenu();
        if (menu == null) return;
        defer _ = win.DestroyMenu(menu);

        _ = win.AppendMenuW(menu, 0, IDM_SETTINGS, toUtf16("Settings..."));
        _ = win.AppendMenuW(menu, 0x0800, 0, null); // MF_SEPARATOR
        _ = win.AppendMenuW(menu, 0, IDM_QUIT, toUtf16("Quit"));

        var pt: win.POINT = undefined;
        _ = win.GetCursorPos(&pt);

        _ = win.SetForegroundWindow(hwnd);
        _ = win.TrackPopupMenu(
            menu,
            win.TPM_BOTTOMALIGN | win.TPM_LEFTALIGN,
            pt.x,
            pt.y,
            0,
            hwnd,
            null,
        );
        _ = win.PostMessageW(hwnd, win.WM_NULL, 0, 0);
    }

    pub fn handleMenuCommand(id: c_uint) bool {
        switch (id) {
            IDM_QUIT => {
                win.PostQuitMessage(0);
                return true;
            },
            else => return false,
        }
    }

    fn copyTip(dest: *[128]win.WCHAR, text: []const u8) void {
        const max_len = dest.len - 1;
        var i: usize = 0;
        while (i < text.len and i < max_len) : (i += 1) {
            dest[i] = @intCast(text[i]);
        }
        dest[i] = 0;
    }

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
};

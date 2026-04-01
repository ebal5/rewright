const std = @import("std");
const builtin = @import("builtin");
const messages = @import("messages");

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "");
    @cInclude("windows.h");
    @cInclude("shellapi.h");
});

const NOTIFYICONDATAW = extern struct {
    cbSize: win.DWORD,
    hWnd: win.HWND,
    uID: win.UINT,
    uFlags: win.UINT,
    uCallbackMessage: win.UINT,
    hIcon: win.HICON,
    szTip: [128]win.WCHAR,
    dwState: win.DWORD = 0,
    dwStateMask: win.DWORD = 0,
    szInfo: [256]win.WCHAR = std.mem.zeroes([256]win.WCHAR),
    uVersion: win.UINT = 0,
    szInfoTitle: [64]win.WCHAR = std.mem.zeroes([64]win.WCHAR),
    dwInfoFlags: win.DWORD = 0,
    guidItem: win.GUID = std.mem.zeroes(win.GUID),
    hBalloonIcon: win.HICON = null,
};

const NIF_MESSAGE = 0x00000001;
const NIF_ICON = 0x00000002;
const NIF_TIP = 0x00000004;
const NIM_ADD = 0x00000000;
const NIM_DELETE = 0x00000002;

// Context menu item IDs
const IDM_QUIT: c_uint = 1001;

extern "shell32" fn Shell_NotifyIconW(dwMessage: win.DWORD, lpData: *NOTIFYICONDATAW) callconv(.c) win.BOOL;

pub const Tray = struct {
    nid: NOTIFYICONDATAW,

    pub fn init(hwnd_opaque: *anyopaque) Tray {
        const hwnd: win.HWND = @ptrCast(@alignCast(hwnd_opaque));
        var nid: NOTIFYICONDATAW = std.mem.zeroes(NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = 1;
        nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        nid.uCallbackMessage = messages.WM_APP_TRAY_CALLBACK;
        // Use system default application icon
        nid.hIcon = win.LoadIconW(null, @ptrFromInt(@as(usize, 32512))); // IDI_APPLICATION = 32512
        copyTip(&nid.szTip, "rewright");

        _ = Shell_NotifyIconW(NIM_ADD, &nid);

        return .{ .nid = nid };
    }

    pub fn deinit(self: *Tray) void {
        _ = Shell_NotifyIconW(NIM_DELETE, &self.nid);
    }

    pub fn showContextMenu(self: *const Tray, hwnd_opaque: *anyopaque) void {
        _ = self;
        const hwnd: win.HWND = @ptrCast(@alignCast(hwnd_opaque));
        const menu = win.CreatePopupMenu();
        if (menu == null) return;
        defer _ = win.DestroyMenu(menu);

        _ = win.AppendMenuW(menu, 0, IDM_QUIT, toUtf16("Quit"));

        // Get cursor position for menu placement
        var pt: win.POINT = undefined;
        _ = win.GetCursorPos(&pt);

        // Required to make the menu dismiss when clicking outside
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
        // Post a dummy message to force the menu to close properly
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

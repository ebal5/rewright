const std = @import("std");
const Config = @import("config").Config;

const win = @cImport({
    @cInclude("windows.h");
});

// =========================================================================
// Constants
// =========================================================================

const CP_UTF8: c_uint = 65001;

// Control IDs
const IDC_WHISPER_MODEL: c_int = 100;
const IDC_WHISPER_LANGUAGE: c_int = 101;
const IDC_LLM_ENABLED: c_int = 102;
const IDC_LLM_API_URL: c_int = 103;
const IDC_LLM_API_KEY: c_int = 104;
const IDC_LLM_MODEL: c_int = 105;
const IDC_LLM_SYSTEM_PROMPT: c_int = 106;
const IDC_CLIPBOARD_ENABLED: c_int = 107;
const IDC_PASTE_ENABLED: c_int = 108;
const IDC_OK: c_int = 109;
const IDC_CANCEL: c_int = 110;

// Window metrics
const DLG_WIDTH: c_int = 450;
// Height is calculated from layout:
// Whisper section: MARGIN + (CONTROL_HEIGHT+2) + 2*ROW_SPACING + SECTION_SPACING = 88
// LLM section: (CONTROL_HEIGHT+2) + 4*ROW_SPACING + PROMPT_HEIGHT + SECTION_SPACING = 256
// Output section: (CONTROL_HEIGHT+2) + 2*ROW_SPACING + SECTION_SPACING = 96
// Buttons + margin: BUTTON_HEIGHT + MARGIN = 44
// Title bar: ~40
// Total: MARGIN + 88 + 256 + 96 + 44 + 40 = 540
const DLG_HEIGHT: c_int = 550;
const MARGIN: c_int = 16;
const LABEL_WIDTH: c_int = 110;
const CONTROL_HEIGHT: c_int = 24;
const ROW_SPACING: c_int = 30;
const SECTION_SPACING: c_int = 10;
const CHECKBOX_WIDTH: c_int = 220;
const BUTTON_WIDTH: c_int = 80;
const BUTTON_HEIGHT: c_int = 28;
const PROMPT_HEIGHT: c_int = 100;

// ComboBox items
const model_items = [_][]const u8{ "tiny", "base", "small", "medium", "large", "turbo" };
const language_items = [_][]const u8{ "auto", "ja", "en", "zh", "ko", "de", "fr", "es" };

// Window styles
const WS_OVERLAPPED = @as(c_ulong, 0x00000000);
const WS_CAPTION = @as(c_ulong, 0x00C00000);
const WS_SYSMENU = @as(c_ulong, 0x00080000);
const WS_CHILD = @as(c_ulong, 0x40000000);
const WS_VISIBLE = @as(c_ulong, 0x10000000);
const WS_TABSTOP = @as(c_ulong, 0x00010000);
const WS_VSCROLL = @as(c_ulong, 0x00200000);
const WS_GROUP = @as(c_ulong, 0x00020000);
const WS_BORDER = @as(c_ulong, 0x00800000);

const CBS_DROPDOWNLIST = @as(c_ulong, 0x0003);
const CBS_HASSTRINGS = @as(c_ulong, 0x0200);

const BS_AUTOCHECKBOX = @as(c_ulong, 0x0003);
const BS_PUSHBUTTON = @as(c_ulong, 0x0000);

const ES_PASSWORD = @as(c_ulong, 0x0020);
const ES_MULTILINE = @as(c_ulong, 0x0004);
const ES_AUTOVSCROLL = @as(c_ulong, 0x0040);
const ES_AUTOHSCROLL = @as(c_ulong, 0x0080);

// Window messages
const CB_ADDSTRING = 0x0143;
const CB_SETCURSEL = 0x014E;
const CB_GETCURSEL = 0x0147;
const BM_SETCHECK = 0x00F1;
const BM_GETCHECK = 0x00F0;
const BST_CHECKED: c_ulong = 1;
const BST_UNCHECKED: c_ulong = 0;

const WM_COMMAND = 0x0111;
const WM_CLOSE = 0x0010;
const WM_DESTROY = 0x0002;
const WM_SETFONT = 0x0030;
const WM_SETTEXT = 0x000C;
const WM_GETTEXT = 0x000D;
const WM_GETTEXTLENGTH = 0x000E;
const WM_CREATE = 0x0001;

const BN_CLICKED = 0;
const HIWORD_SHIFT = 16;

const CW_USEDEFAULT = @as(c_int, @bitCast(@as(c_uint, 0x80000000)));

const SW_SHOW = 5;

const COLOR_BTNFACE = 15;

// =========================================================================
// Module-level dialog state
// =========================================================================

var g_config: ?*Config = null;
var g_result: bool = false;
var g_dialog_hwnd: usize = 0;
var g_parent_hwnd: usize = 0;
var g_font: usize = 0;

// Control handles stored as usize
var g_model_combo: usize = 0;
var g_language_combo: usize = 0;
var g_llm_enabled_check: usize = 0;
var g_llm_api_url_edit: usize = 0;
var g_llm_api_key_edit: usize = 0;
var g_llm_model_edit: usize = 0;
var g_llm_system_prompt_edit: usize = 0;
var g_clipboard_check: usize = 0;
var g_paste_check: usize = 0;

// =========================================================================
// Handle conversion utilities
// =========================================================================

/// Convert a raw handle (usize) to win.HWND without alignment checks.
fn hwndFromInt(raw: usize) win.HWND {
    var val = raw;
    return @as(*const win.HWND, @ptrCast(&val)).*;
}

/// Convert win.HWND to usize for storage.
fn intFromHwnd(hwnd: win.HWND) usize {
    return @intFromPtr(hwnd);
}

/// Convert a raw usize to HFONT.
fn hfontFromInt(raw: usize) win.HFONT {
    var val = raw;
    return @as(*const win.HFONT, @ptrCast(&val)).*;
}

/// Convert a raw usize to HMENU (used for child control IDs).
fn hmenuFromInt(raw: usize) win.HMENU {
    var val = raw;
    return @as(*const win.HMENU, @ptrCast(&val)).*;
}

/// Convert a raw usize to HBRUSH.
fn hbrushFromInt(raw: usize) win.HBRUSH {
    var val = raw;
    return @as(*const win.HBRUSH, @ptrCast(&val)).*;
}

// =========================================================================
// UTF-16 / UTF-8 conversion helpers
// =========================================================================

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

/// Convert a runtime UTF-8 slice to a null-terminated UTF-16 buffer.
/// Returns the number of wide chars written (excluding null), or 0 on failure.
fn utf8ToUtf16(utf8: []const u8, wbuf: []win.WCHAR) usize {
    if (utf8.len == 0) {
        if (wbuf.len > 0) wbuf[0] = 0;
        return 0;
    }
    const result = win.MultiByteToWideChar(
        CP_UTF8,
        0,
        @ptrCast(utf8.ptr),
        @intCast(utf8.len),
        @ptrCast(wbuf.ptr),
        @intCast(wbuf.len - 1), // leave room for null
    );
    if (result <= 0) {
        if (wbuf.len > 0) wbuf[0] = 0;
        return 0;
    }
    const count: usize = @intCast(result);
    if (count < wbuf.len) {
        wbuf[count] = 0;
    }
    return count;
}

/// Convert a null-terminated UTF-16 buffer to UTF-8, returning an allocated slice.
/// Caller must free with page_allocator.
fn utf16ToUtf8Alloc(wstr: [*]const win.WCHAR, wlen: usize) ?[]u8 {
    if (wlen == 0) {
        // Return an empty allocated slice
        const buf = std.heap.page_allocator.alloc(u8, 1) catch return null;
        buf[0] = 0;
        return buf[0..0];
    }
    // First call to get required size
    const size = win.WideCharToMultiByte(
        CP_UTF8,
        0,
        @ptrCast(wstr),
        @intCast(wlen),
        null,
        0,
        null,
        null,
    );
    if (size <= 0) return null;
    const usize_size: usize = @intCast(size);
    const buf = std.heap.page_allocator.alloc(u8, usize_size) catch return null;
    const written = win.WideCharToMultiByte(
        CP_UTF8,
        0,
        @ptrCast(wstr),
        @intCast(wlen),
        @ptrCast(buf.ptr),
        size,
        null,
        null,
    );
    if (written <= 0) {
        std.heap.page_allocator.free(buf);
        return null;
    }
    return buf[0..@intCast(written)];
}

// =========================================================================
// Control creation helpers
// =========================================================================

fn createLabel(parent: win.HWND, hInstance: win.HINSTANCE, text: [*:0]const win.WCHAR, x: c_int, y: c_int, w: c_int, h: c_int) void {
    const hwnd = win.CreateWindowExW(
        0,
        toUtf16("STATIC"),
        text,
        WS_CHILD | WS_VISIBLE,
        x,
        y,
        w,
        h,
        parent,
        null,
        hInstance,
        null,
    );
    if (hwnd) |h_valid| {
        _ = win.SendMessageW(h_valid, WM_SETFONT, @intFromPtr(hfontFromInt(g_font)), 1);
    }
}

fn createEdit(parent: win.HWND, hInstance: win.HINSTANCE, id: c_int, x: c_int, y: c_int, w: c_int, h: c_int, style_extra: c_ulong) usize {
    const style = WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL | style_extra;
    const hwnd = win.CreateWindowExW(
        0,
        toUtf16("EDIT"),
        toUtf16(""),
        style,
        x,
        y,
        w,
        h,
        parent,
        hmenuFromInt(@intCast(id)),
        hInstance,
        null,
    );
    if (hwnd) |h_valid| {
        _ = win.SendMessageW(h_valid, WM_SETFONT, @intFromPtr(hfontFromInt(g_font)), 1);
        return intFromHwnd(h_valid);
    }
    return 0;
}

fn createComboBox(parent: win.HWND, hInstance: win.HINSTANCE, id: c_int, x: c_int, y: c_int, w: c_int, h: c_int) usize {
    const style = WS_CHILD | WS_VISIBLE | WS_TABSTOP | CBS_DROPDOWNLIST | CBS_HASSTRINGS;
    const hwnd = win.CreateWindowExW(
        0,
        toUtf16("COMBOBOX"),
        toUtf16(""),
        style,
        x,
        y,
        w,
        // Drop-down height (total including list area)
        h + 200,
        parent,
        hmenuFromInt(@intCast(id)),
        hInstance,
        null,
    );
    if (hwnd) |h_valid| {
        _ = win.SendMessageW(h_valid, WM_SETFONT, @intFromPtr(hfontFromInt(g_font)), 1);
        return intFromHwnd(h_valid);
    }
    return 0;
}

fn createCheckBox(parent: win.HWND, hInstance: win.HINSTANCE, id: c_int, text: [*:0]const win.WCHAR, x: c_int, y: c_int, w: c_int, h: c_int) usize {
    const style = WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX;
    const hwnd = win.CreateWindowExW(
        0,
        toUtf16("BUTTON"),
        text,
        style,
        x,
        y,
        w,
        h,
        parent,
        hmenuFromInt(@intCast(id)),
        hInstance,
        null,
    );
    if (hwnd) |h_valid| {
        _ = win.SendMessageW(h_valid, WM_SETFONT, @intFromPtr(hfontFromInt(g_font)), 1);
        return intFromHwnd(h_valid);
    }
    return 0;
}

fn createButton(parent: win.HWND, hInstance: win.HINSTANCE, id: c_int, text: [*:0]const win.WCHAR, x: c_int, y: c_int, w: c_int, h: c_int) void {
    const style = WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON;
    const hwnd = win.CreateWindowExW(
        0,
        toUtf16("BUTTON"),
        text,
        style,
        x,
        y,
        w,
        h,
        parent,
        hmenuFromInt(@intCast(id)),
        hInstance,
        null,
    );
    if (hwnd) |h_valid| {
        _ = win.SendMessageW(h_valid, WM_SETFONT, @intFromPtr(hfontFromInt(g_font)), 1);
    }
}

// =========================================================================
// Control value helpers
// =========================================================================

fn addComboString(combo_hwnd: usize, text: []const u8) void {
    var wbuf: [256]win.WCHAR = undefined;
    _ = utf8ToUtf16(text, &wbuf);
    _ = win.SendMessageW(hwndFromInt(combo_hwnd), CB_ADDSTRING, 0, @as(win.LPARAM, @bitCast(@intFromPtr(&wbuf))));
}

fn setComboSelection(combo_hwnd: usize, index: usize) void {
    _ = win.SendMessageW(hwndFromInt(combo_hwnd), CB_SETCURSEL, index, 0);
}

fn getComboSelection(combo_hwnd: usize) usize {
    const result = win.SendMessageW(hwndFromInt(combo_hwnd), CB_GETCURSEL, 0, 0);
    if (result < 0) return 0;
    return @intCast(result);
}

fn setCheckBox(check_hwnd: usize, checked: bool) void {
    _ = win.SendMessageW(hwndFromInt(check_hwnd), BM_SETCHECK, if (checked) BST_CHECKED else BST_UNCHECKED, 0);
}

fn getCheckBox(check_hwnd: usize) bool {
    const result = win.SendMessageW(hwndFromInt(check_hwnd), BM_GETCHECK, 0, 0);
    return result == BST_CHECKED;
}

fn setEditText(edit_hwnd: usize, text: []const u8) void {
    var wbuf: [2048]win.WCHAR = undefined;
    _ = utf8ToUtf16(text, &wbuf);
    _ = win.SendMessageW(hwndFromInt(edit_hwnd), WM_SETTEXT, 0, @as(win.LPARAM, @bitCast(@intFromPtr(&wbuf))));
}

/// Read text from an edit control, returning an allocated UTF-8 slice.
/// Caller must free with page_allocator.
fn getEditText(edit_hwnd: usize) ?[]u8 {
    const len_raw = win.SendMessageW(hwndFromInt(edit_hwnd), WM_GETTEXTLENGTH, 0, 0);
    if (len_raw <= 0) {
        // Return empty allocated slice
        const buf = std.heap.page_allocator.alloc(u8, 1) catch return null;
        buf[0] = 0;
        return buf[0..0];
    }
    const wlen: usize = @intCast(len_raw);
    // Allocate wide char buffer (+1 for null)
    const wbuf = std.heap.page_allocator.alloc(win.WCHAR, wlen + 1) catch return null;
    defer std.heap.page_allocator.free(wbuf);

    _ = win.SendMessageW(
        hwndFromInt(edit_hwnd),
        WM_GETTEXT,
        wbuf.len,
        @as(win.LPARAM, @bitCast(@intFromPtr(wbuf.ptr))),
    );

    return utf16ToUtf8Alloc(wbuf.ptr, wlen);
}

// =========================================================================
// Find combo index matching a string value
// =========================================================================

fn findComboIndex(comptime items: []const []const u8, value: []const u8) usize {
    for (items, 0..) |item, idx| {
        if (std.mem.eql(u8, item, value)) return idx;
    }
    return 0; // default to first item
}

// =========================================================================
// Populate controls from config
// =========================================================================

fn populateControls() void {
    const config = g_config orelse return;

    // Whisper model
    for (&model_items) |item| {
        addComboString(g_model_combo, item);
    }
    setComboSelection(g_model_combo, findComboIndex(&model_items, config.whisper_model));

    // Language
    for (&language_items) |item| {
        addComboString(g_language_combo, item);
    }
    setComboSelection(g_language_combo, findComboIndex(&language_items, config.language));

    // LLM settings
    setCheckBox(g_llm_enabled_check, config.llm_enabled);
    setEditText(g_llm_api_url_edit, config.llm_api_url);
    setEditText(g_llm_api_key_edit, config.llm_api_key);
    setEditText(g_llm_model_edit, config.llm_model);
    setEditText(g_llm_system_prompt_edit, config.llm_system_prompt);

    // Output settings
    setCheckBox(g_clipboard_check, config.clipboard_enabled);
    setCheckBox(g_paste_check, config.paste_enabled);
}

// =========================================================================
// Read controls back into config
// =========================================================================

fn readControlsIntoConfig() void {
    const config = g_config orelse return;

    // Whisper model
    const model_idx = getComboSelection(g_model_combo);
    if (model_idx < model_items.len) {
        config.whisper_model = model_items[model_idx];
    }

    // Language
    const lang_idx = getComboSelection(g_language_combo);
    if (lang_idx < language_items.len) {
        config.language = language_items[lang_idx];
    }

    // LLM settings
    config.llm_enabled = getCheckBox(g_llm_enabled_check);

    if (getEditText(g_llm_api_url_edit)) |text| {
        config.llm_api_url = text;
    }
    if (getEditText(g_llm_api_key_edit)) |text| {
        config.llm_api_key = text;
    }
    if (getEditText(g_llm_model_edit)) |text| {
        config.llm_model = text;
    }
    if (getEditText(g_llm_system_prompt_edit)) |text| {
        config.llm_system_prompt = text;
    }

    // Output settings
    config.clipboard_enabled = getCheckBox(g_clipboard_check);
    config.paste_enabled = getCheckBox(g_paste_check);
}

// =========================================================================
// Window procedure
// =========================================================================

fn settingsWndProc(hwnd: win.HWND, uMsg: c_uint, wParam: win.WPARAM, lParam: win.LPARAM) callconv(.c) win.LRESULT {
    switch (uMsg) {
        WM_CREATE => {
            return 0;
        },
        WM_COMMAND => {
            const id: c_int = @intCast(wParam & 0xFFFF);
            const notification: c_uint = @truncate(wParam >> HIWORD_SHIFT);

            if (notification == BN_CLICKED) {
                if (id == IDC_OK) {
                    readControlsIntoConfig();
                    g_result = true;
                    _ = win.DestroyWindow(hwnd);
                    return 0;
                } else if (id == IDC_CANCEL) {
                    g_result = false;
                    _ = win.DestroyWindow(hwnd);
                    return 0;
                }
            }
            return 0;
        },
        WM_CLOSE => {
            g_result = false;
            _ = win.DestroyWindow(hwnd);
            return 0;
        },
        WM_DESTROY => {
            // Re-enable parent window
            if (g_parent_hwnd != 0) {
                _ = win.EnableWindow(hwndFromInt(g_parent_hwnd), 1);
            }
            // Clean up font
            if (g_font != 0) {
                _ = win.DeleteObject(hfontFromInt(g_font));
                g_font = 0;
            }
            win.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return win.DefWindowProcW(hwnd, uMsg, wParam, lParam);
}

// =========================================================================
// Public API
// =========================================================================

/// Show a modal settings dialog.
/// Returns true if the user clicked OK (config was modified), false if Cancel.
pub fn showSettingsDialog(parent_hwnd: usize, config: *Config) bool {
    g_config = config;
    g_result = false;
    g_parent_hwnd = parent_hwnd;
    g_dialog_hwnd = 0;

    const hInstance: win.HINSTANCE = @ptrCast(win.GetModuleHandleW(null));

    // Create font
    g_font = @intFromPtr(win.CreateFontW(
        -14, // height (negative = character height)
        0, // width
        0, // escapement
        0, // orientation
        400, // weight (FW_NORMAL)
        0, // italic
        0, // underline
        0, // strikeout
        0, // charset (DEFAULT_CHARSET)
        0, // out precision
        0, // clip precision
        0, // quality
        0, // pitch and family
        toUtf16("Segoe UI"),
    ));

    // Register window class
    var wc: win.WNDCLASSEXW = std.mem.zeroes(win.WNDCLASSEXW);
    wc.cbSize = @sizeOf(win.WNDCLASSEXW);
    wc.lpfnWndProc = settingsWndProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = toUtf16("RewrightSettingsClass");
    wc.hbrBackground = hbrushFromInt(COLOR_BTNFACE + 1);
    wc.hCursor = win.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW

    _ = win.RegisterClassExW(&wc);

    // Center on screen
    const screen_w = win.GetSystemMetrics(0); // SM_CXSCREEN
    const screen_h = win.GetSystemMetrics(1); // SM_CYSCREEN
    const x = @divTrunc(screen_w - DLG_WIDTH, 2);
    const y = @divTrunc(screen_h - DLG_HEIGHT, 2);

    // Create dialog window
    const dialog = win.CreateWindowExW(
        0,
        toUtf16("RewrightSettingsClass"),
        toUtf16("rewright - Settings"),
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        x,
        y,
        DLG_WIDTH,
        DLG_HEIGHT,
        if (parent_hwnd != 0) hwndFromInt(parent_hwnd) else null,
        null,
        hInstance,
        null,
    );

    if (dialog == null) {
        if (g_font != 0) {
            _ = win.DeleteObject(hfontFromInt(g_font));
            g_font = 0;
        }
        return false;
    }

    const dlg_hwnd = dialog.?;
    g_dialog_hwnd = intFromHwnd(dlg_hwnd);

    // Disable parent to make dialog modal
    if (parent_hwnd != 0) {
        _ = win.EnableWindow(hwndFromInt(parent_hwnd), 0);
    }

    // =====================================================================
    // Create controls
    // =====================================================================
    const content_width = DLG_WIDTH - 2 * MARGIN - 16; // account for window border
    const edit_x = MARGIN + LABEL_WIDTH + 4;
    const edit_width = content_width - LABEL_WIDTH - 4;
    var cur_y: c_int = MARGIN;

    // --- Section: Whisper ---
    createLabel(dlg_hwnd, hInstance, toUtf16("Whisper"), MARGIN, cur_y, content_width, CONTROL_HEIGHT);
    cur_y += CONTROL_HEIGHT + 2;

    // Model
    createLabel(dlg_hwnd, hInstance, toUtf16("Model:"), MARGIN, cur_y + 2, LABEL_WIDTH, CONTROL_HEIGHT);
    g_model_combo = createComboBox(dlg_hwnd, hInstance, IDC_WHISPER_MODEL, edit_x, cur_y, edit_width, CONTROL_HEIGHT);
    cur_y += ROW_SPACING;

    // Language
    createLabel(dlg_hwnd, hInstance, toUtf16("Language:"), MARGIN, cur_y + 2, LABEL_WIDTH, CONTROL_HEIGHT);
    g_language_combo = createComboBox(dlg_hwnd, hInstance, IDC_WHISPER_LANGUAGE, edit_x, cur_y, edit_width, CONTROL_HEIGHT);
    cur_y += ROW_SPACING + SECTION_SPACING;

    // --- Section: LLM ---
    createLabel(dlg_hwnd, hInstance, toUtf16("LLM"), MARGIN, cur_y, content_width, CONTROL_HEIGHT);
    cur_y += CONTROL_HEIGHT + 2;

    // Enable LLM checkbox
    g_llm_enabled_check = createCheckBox(dlg_hwnd, hInstance, IDC_LLM_ENABLED, toUtf16("Enable LLM cleanup"), MARGIN, cur_y, CHECKBOX_WIDTH, CONTROL_HEIGHT);
    cur_y += ROW_SPACING;

    // API URL
    createLabel(dlg_hwnd, hInstance, toUtf16("API URL:"), MARGIN, cur_y + 2, LABEL_WIDTH, CONTROL_HEIGHT);
    g_llm_api_url_edit = createEdit(dlg_hwnd, hInstance, IDC_LLM_API_URL, edit_x, cur_y, edit_width, CONTROL_HEIGHT, 0);
    cur_y += ROW_SPACING;

    // API Key
    createLabel(dlg_hwnd, hInstance, toUtf16("API Key:"), MARGIN, cur_y + 2, LABEL_WIDTH, CONTROL_HEIGHT);
    g_llm_api_key_edit = createEdit(dlg_hwnd, hInstance, IDC_LLM_API_KEY, edit_x, cur_y, edit_width, CONTROL_HEIGHT, ES_PASSWORD);
    cur_y += ROW_SPACING;

    // LLM Model
    createLabel(dlg_hwnd, hInstance, toUtf16("Model:"), MARGIN, cur_y + 2, LABEL_WIDTH, CONTROL_HEIGHT);
    g_llm_model_edit = createEdit(dlg_hwnd, hInstance, IDC_LLM_MODEL, edit_x, cur_y, edit_width, CONTROL_HEIGHT, 0);
    cur_y += ROW_SPACING;

    // System Prompt
    createLabel(dlg_hwnd, hInstance, toUtf16("System Prompt:"), MARGIN, cur_y + 2, LABEL_WIDTH, CONTROL_HEIGHT);
    g_llm_system_prompt_edit = createEdit(dlg_hwnd, hInstance, IDC_LLM_SYSTEM_PROMPT, edit_x, cur_y, edit_width, PROMPT_HEIGHT, ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL);
    cur_y += PROMPT_HEIGHT + SECTION_SPACING;

    // --- Section: Output ---
    createLabel(dlg_hwnd, hInstance, toUtf16("Output"), MARGIN, cur_y, content_width, CONTROL_HEIGHT);
    cur_y += CONTROL_HEIGHT + 2;

    // Clipboard checkbox
    g_clipboard_check = createCheckBox(dlg_hwnd, hInstance, IDC_CLIPBOARD_ENABLED, toUtf16("Copy to clipboard"), MARGIN, cur_y, CHECKBOX_WIDTH, CONTROL_HEIGHT);
    cur_y += ROW_SPACING;

    // Paste checkbox
    g_paste_check = createCheckBox(dlg_hwnd, hInstance, IDC_PASTE_ENABLED, toUtf16("Paste at cursor position"), MARGIN, cur_y, CHECKBOX_WIDTH, CONTROL_HEIGHT);
    cur_y += ROW_SPACING + SECTION_SPACING;

    // --- Buttons ---
    const buttons_y = cur_y;
    const ok_x = DLG_WIDTH - 2 * BUTTON_WIDTH - MARGIN - 16 - 8;
    const cancel_x = DLG_WIDTH - BUTTON_WIDTH - MARGIN - 16;
    createButton(dlg_hwnd, hInstance, IDC_OK, toUtf16("OK"), ok_x, buttons_y, BUTTON_WIDTH, BUTTON_HEIGHT);
    createButton(dlg_hwnd, hInstance, IDC_CANCEL, toUtf16("Cancel"), cancel_x, buttons_y, BUTTON_WIDTH, BUTTON_HEIGHT);

    // =====================================================================
    // Populate controls from config
    // =====================================================================
    populateControls();

    // Show the dialog
    _ = win.ShowWindow(dlg_hwnd, SW_SHOW);
    _ = win.UpdateWindow(dlg_hwnd);

    // =====================================================================
    // Local message loop
    // =====================================================================
    var msg: win.MSG = undefined;
    while (win.GetMessageW(&msg, null, 0, 0) > 0) {
        // Allow Tab navigation via IsDialogMessage
        if (win.IsDialogMessageW(dlg_hwnd, &msg) == 0) {
            _ = win.TranslateMessage(&msg);
            _ = win.DispatchMessageW(&msg);
        }
    }

    // Unregister class (ignore failure)
    _ = win.UnregisterClassW(toUtf16("RewrightSettingsClass"), hInstance);

    return g_result;
}

/// Custom Windows message constants for inter-thread communication.
/// Based on WM_APP (0x8000) to avoid conflicts with system messages.

const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "");
    @cInclude("windows.h");
});

pub const WM_APP_TRAY_CALLBACK: c_uint = win.WM_APP + 1;
pub const WM_APP_START_RECORDING: c_uint = win.WM_APP + 2;
pub const WM_APP_STOP_RECORDING: c_uint = win.WM_APP + 3;
pub const WM_APP_TRANSCRIPTION_DONE: c_uint = win.WM_APP + 4;
pub const WM_APP_UPDATE_OVERLAY: c_uint = win.WM_APP + 5;

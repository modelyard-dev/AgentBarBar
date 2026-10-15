//! Taskbar colors may differ from application colors in Windows Custom mode.
//! Read the user's system/taskbar preference without modifying the registry.
pub fn icon_bytes() -> &'static [u8] {
    if taskbar_dark() {
        include_bytes!("../icons/tray-light.png")
    } else {
        include_bytes!("../icons/tray-dark.png")
    }
}
fn taskbar_dark() -> bool {
    #[cfg(windows)]
    {
        #[link(name = "advapi32")]
        extern "system" {
            fn RegGetValueW(key: *mut std::ffi::c_void, subkey: *const u16,
                name: *const u16, flags: u32, kind: *mut u32,
                data: *mut std::ffi::c_void, size: *mut u32) -> i32;
        }
        let path: Vec<u16> = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".encode_utf16().chain(Some(0)).collect();
        let name: Vec<u16> = "SystemUsesLightTheme".encode_utf16().chain(Some(0)).collect();
        let mut value: u32 = 1;
        let mut size = std::mem::size_of::<u32>() as u32;
        // Predefined HKEY values are sign-extended on Win64.
        let key = (0x80000001u32 as i32 as isize) as *mut std::ffi::c_void;
        let result = unsafe { RegGetValueW(key, path.as_ptr(), name.as_ptr(), 0x10,
            std::ptr::null_mut(), (&mut value as *mut u32).cast(), &mut size) };
        result == 0 && value == 0
    }
    #[cfg(not(windows))]
    { false }
}
pub fn refresh(app: &tauri::AppHandle) {
    if let Some(tray) = app.tray_by_id("agentbarbar") {
        if let Ok(icon) = tauri::image::Image::from_bytes(icon_bytes()) {
            let _ = tray.set_icon(Some(icon));
        }
    }
}

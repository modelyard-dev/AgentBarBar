use crate::runtime::{Runtime, Work};
use agentbar_windows_host::geometry::{self, Rect};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Instant,
};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{
    Emitter, Listener, Manager, PhysicalPosition, PhysicalSize, RunEvent, WebviewUrl,
    WebviewWindowBuilder, WindowEvent,
};
#[derive(Serialize)]
struct BridgeError {
    code: &'static str,
    message: &'static str,
    recoverable: bool,
}
fn error() -> BridgeError {
    BridgeError {
        code: "REQUEST_FAILED",
        message: "Local operation could not be completed",
        recoverable: true,
    }
}
#[tauri::command]
async fn business_request(
    state: tauri::State<'_, Arc<Runtime>>,
    method: String,
    path: String,
    body: Option<Value>,
) -> std::result::Result<Value, BridgeError> {
    let r = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || match (method.as_str(), path.as_str()) {
        ("POST", "sync") => {
            r.sender.try_send(Work::Sync).map_err(|_| error())?;
            Ok(json!({"scheduled":true,"collecting":true}))
        }
        ("POST", "token-survey") => {
            let agent = body
                .as_ref()
                .and_then(|v| v["agentID"].as_str())
                .filter(|s| {
                    agentbar_windows_host::data::AGENTS
                        .iter()
                        .any(|(id, _)| id == s)
                })
                .ok_or_else(error)?
                .to_owned();
            let (tx, rx) = std::sync::mpsc::sync_channel(1);
            r.sender
                .try_send(Work::Survey(agent, tx))
                .map_err(|_| error())?;
            rx.recv_timeout(std::time::Duration::from_secs(120))
                .map_err(|_| error())?
                .map_err(|_| error())
        }
        ("POST", "settings") => {
            let (tx, rx) = std::sync::mpsc::sync_channel(1);
            r.sender
                .try_send(Work::Settings(body.ok_or_else(error)?, tx))
                .map_err(|_| error())?;
            rx.recv_timeout(std::time::Duration::from_secs(30))
                .map_err(|_| error())?
                .map_err(|_| BridgeError {
                    code: "INVALID_SETTINGS",
                    message: "Invalid or unsupported settings",
                    recoverable: true,
                })
        }
        ("GET", _) => r.read(&path).map_err(|_| error()),
        _ => Err(BridgeError {
            code: "NOT_SUPPORTED",
            message: "This operation is not available",
            recoverable: false,
        }),
    })
    .await
    .map_err(|_| error())?
}
#[tauri::command]
async fn window_action(
    app: tauri::AppHandle,
    action: String,
) -> std::result::Result<(), BridgeError> {
    match action.as_str() {
        "open-tibo" => open_tibo().map_err(|_| BridgeError {
            code: "BROWSER_OPEN_FAILED",
            message: "Could not open the default browser. Please open https://tibo.modelyard.dev/ manually.",
            recoverable: true,
        }),
        "dashboard" => {
            show_dashboard(&app, false);
            Ok(())
        }
        "settings" => {
            show_dashboard(&app, true);
            Ok(())
        }
        "hide-popup" => {
            if let Some(w) = app.get_webview_window("popup") {
                let _ = w.hide();
            }
            Ok(())
        }
        "quit" => {
            app.exit(0);
            Ok(())
        }
        _ => Err(error()),
    }
}
fn open_tibo() -> Result<(), ()> {
    #[link(name = "shell32")]
    extern "system" {
        fn ShellExecuteW(
            window: *mut std::ffi::c_void,
            operation: *const u16,
            file: *const u16,
            parameters: *const u16,
            directory: *const u16,
            show: i32,
        ) -> isize;
    }
    let operation: Vec<u16> = "open\0".encode_utf16().collect();
    let target: Vec<u16> = "https://tibo.modelyard.dev/\0".encode_utf16().collect();
    // Only this fixed HTTPS resource is exposed to the frontend. Windows resolves
    // its default browser; no shell command or caller-supplied path is executed.
    let result = unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            operation.as_ptr(),
            target.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            1,
        )
    };
    if result > 32 {
        Ok(())
    } else {
        Err(())
    }
}
#[tauri::command]
fn front_ready(app: tauri::AppHandle, window: tauri::WebviewWindow) -> Value {
    record(&app, "frontend_ready", json!({"window":window.label()}));
    json!({"ready":true})
}
#[cfg(feature = "qa")]
#[tauri::command]
fn qa_result(app: tauri::AppHandle, window: tauri::WebviewWindow, result: Value) {
    let root = agentbar_collector::cli::default_database()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("state");
    let _ = std::fs::create_dir_all(&root);
    let _ = std::fs::write(
        root.join(format!("qa-dom-{}.json", window.label())),
        serde_json::to_vec(&result).unwrap(),
    );
    record(&app, "qa_dom", json!({"window":window.label()}));
}
struct PopupLayout(std::sync::Mutex<f64>);
#[tauri::command]
fn popup_layout(
    app: tauri::AppHandle,
    window: tauri::WebviewWindow,
    height: f64,
) -> std::result::Result<(), BridgeError> {
    if window.label() != "popup" || !height.is_finite() || !(100.0..=2000.0).contains(&height) {
        return Err(error());
    }
    *app.state::<PopupLayout>().0.lock().unwrap() = height.clamp(220., 720.);
    if window.is_visible().unwrap_or(false) {
        position_popup(&app, &window);
    }
    Ok(())
}
struct ExitState {
    stopping: AtomicBool,
    done: AtomicBool,
}
fn prefs(app: &tauri::AppHandle) -> Value {
    app.try_state::<Arc<Runtime>>()
        .and_then(|r| r.read("settings").ok())
        .unwrap_or_else(agentbar_windows_host::data::defaults)
}
fn record(app: &tauri::AppHandle, event: &str, extra: Value) {
    let root = agentbar_collector::cli::default_database()
        .ok()
        .and_then(|p| p.parent().and_then(|p| p.parent()).map(|p| p.to_path_buf()));
    if let Some(root) = root {
        let _ = std::fs::create_dir_all(root.join("logs"));
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(root.join("logs/host.jsonl"))
        {
            let _ = writeln!(
                f,
                "{}",
                json!({"timestamp":agentbar_core::domain::iso(chrono::Utc::now()),"component":"windows-host","level":"info","event":event,"detail":extra})
            );
        }
        let _ = std::fs::create_dir_all(root.join("state"));
        let windows=app.webview_windows().values().map(|w|json!({"label":w.label(),"visible":w.is_visible().unwrap_or(false),"position":w.outer_position().ok(),"size":w.outer_size().ok(),"scale":w.scale_factor().ok()})).collect::<Vec<_>>();
        let tray = app
            .tray_by_id("agentbarbar")
            .and_then(|t| t.rect().ok().flatten());
        let h = app
            .try_state::<Arc<Runtime>>()
            .map(|r| r.health.lock().unwrap().clone());
        let _=std::fs::write(root.join("state/host.json"),serde_json::to_vec(&json!({"pid":std::process::id(),"event":event,"trayRect":tray,"windows":windows,"health":h})).unwrap());
    }
}
fn system_chinese() -> bool {
    #[cfg(windows)]
    {
        #[link(name = "kernel32")]
        extern "system" {
            fn GetUserDefaultUILanguage() -> u16;
        }
        unsafe { GetUserDefaultUILanguage() & 0x3ff == 4 }
    }
    #[cfg(not(windows))]
    {
        false
    }
}
fn menu(app: &tauri::AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let preference = prefs(app)["language"]
        .as_str()
        .unwrap_or("system")
        .to_owned();
    let zh = preference == "zh-Hans" || (preference == "system" && system_chinese());
    let catalogue: Value =
        serde_json::from_str(include_str!("../../../Dashboard/src/locales/zh-Hans.json")).unwrap();
    let label = |key: &str| {
        if zh {
            catalogue[key].as_str().unwrap_or(key).to_owned()
        } else {
            key.to_owned()
        }
    };
    let show = MenuItem::with_id(app, "show", label("Show AgentBarBar"), true, None::<&str>)?;
    let settings = MenuItem::with_id(app, "settings", label("Settings"), true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", label("Quit"), true, None::<&str>)?;
    Menu::with_items(app, &[&show, &settings, &quit])
}
fn build_window(
    app: &tauri::AppHandle,
    label: &str,
    popup: bool,
) -> tauri::Result<tauri::WebviewWindow> {
    let path = if popup { "popup.html" } else { "index.html" };
    WebviewWindowBuilder::new(app, label, WebviewUrl::App(path.into()))
        .title(if popup {
            "AgentBarBar Popup"
        } else {
            "AgentBarBar"
        })
        .inner_size(
            if popup { 320. } else { 1200. },
            if popup { 367. } else { 860. },
        )
        .min_inner_size(
            if popup { 220. } else { 640. },
            if popup { 220. } else { 480. },
        )
        .visible(false)
        .decorations(!popup)
        .skip_taskbar(popup)
        .resizable(!popup)
        .always_on_top(popup)
        .shadow(!popup)
        .devtools(cfg!(debug_assertions))
        .additional_browser_args("--force-renderer-accessibility")
        .data_directory(
            agentbar_collector::cli::default_database()
                .unwrap()
                .parent()
                .unwrap()
                .parent()
                .unwrap()
                .join("cache/webview2"),
        )
        .on_navigation(|url| {
            matches!(url.scheme(), "tauri" | "about") || url.host_str() == Some("tauri.localhost")
        })
        .build()
}
fn show_dashboard(app: &tauri::AppHandle, settings: bool) {
    let w = match app.get_webview_window("dashboard") {
        Some(w) => w,
        None => match build_window(app, "dashboard", false) {
            Ok(w) => w,
            Err(_) => {
                record(
                    app,
                    "webview_creation_failed",
                    json!({"code":"WEBVIEW2_UNAVAILABLE_OR_INITIALIZATION_FAILED"}),
                );
                return;
            }
        },
    };
    if settings {
        let _ = w
            .eval("window.dispatchEvent(new CustomEvent('agentbar:navigate',{detail:'settings'}))");
    }
    if !w.is_visible().unwrap_or(false) {
        restore_window(&w);
    }
    let _ = w.show();
    let _ = w.set_focus();
    record(app, "dashboard_shown", json!({}));
}
fn show_popup(app: &tauri::AppHandle, toggle: bool) {
    let w = match app.get_webview_window("popup") {
        Some(w) => w,
        None => match build_window(app, "popup", true) {
            Ok(w) => w,
            Err(_) => {
                record(
                    app,
                    "webview_creation_failed",
                    json!({"code":"WEBVIEW2_UNAVAILABLE_OR_INITIALIZATION_FAILED"}),
                );
                return;
            }
        },
    };
    if toggle && w.is_visible().unwrap_or(false) {
        let _ = w.hide();
        record(app, "popup_hidden", json!({}));
        return;
    }
    let _ = w.show();
    position_popup(app, &w);
    let _ = w.set_focus();
    let _ = app.emit("data_updated", json!({}));
    record(app, "popup_shown", json!({}));
}

fn position_popup(app: &tauri::AppHandle, w: &tauri::WebviewWindow) {
    let mut bounds = None;
    if let Some(tray) = app.tray_by_id("agentbarbar") {
        if let Ok(Some(rect)) = tray.rect() {
            let pos = rect.position.to_physical::<i32>(1.);
            let size = rect.size.to_physical::<u32>(1.);
            let monitor = w
                .monitor_from_point(pos.x as f64, pos.y as f64)
                .ok()
                .flatten()
                .or_else(|| w.primary_monitor().ok().flatten());
            if let Some(m) = monitor {
                let work = m.work_area();
                let p = geometry::popup_sized(
                    Rect {
                        x: pos.x,
                        y: pos.y,
                        w: size.width as i32,
                        h: size.height as i32,
                    },
                    Rect {
                        x: work.position.x,
                        y: work.position.y,
                        w: work.size.width as i32,
                        h: work.size.height as i32,
                    },
                    m.scale_factor(),
                    *app.state::<PopupLayout>().0.lock().unwrap(),
                );
                bounds = Some(p);
                let _ = w.set_size(PhysicalSize::new(p.w as u32, p.h as u32));
                let _ = w.set_position(PhysicalPosition::new(p.x, p.y));
            }
        }
    }
    native_popup(w, bounds);
    record(
        app,
        "popup_layout_applied",
        json!({"height":*app.state::<PopupLayout>().0.lock().unwrap()}),
    );
}
#[cfg(windows)]
#[link(name = "user32")]
extern "system" {
    fn GetWindowLongPtrW(h: *mut std::ffi::c_void, index: i32) -> isize;
    fn SetWindowLongPtrW(h: *mut std::ffi::c_void, index: i32, value: isize) -> isize;
    fn SetWindowPos(
        h: *mut std::ffi::c_void,
        after: *mut std::ffi::c_void,
        x: i32,
        y: i32,
        w: i32,
        height: i32,
        flags: u32,
    ) -> i32;
    fn GetForegroundWindow() -> *mut std::ffi::c_void;
    fn IsChild(parent: *mut std::ffi::c_void, child: *mut std::ffi::c_void) -> i32;
}
fn native_popup(w: &tauri::WebviewWindow, bounds: Option<Rect>) {
    #[cfg(windows)]
    if let (Ok(hwnd), Ok(p), Ok(size)) = (w.hwnd(), w.outer_position(), w.inner_size()) {
        unsafe {
            let h = hwnd.0;
            let style = GetWindowLongPtrW(h, -16);
            SetWindowLongPtrW(h, -16, (style & !0x00CF0000isize) | 0x80000000u32 as isize);
            let ex = GetWindowLongPtrW(h, -20);
            SetWindowLongPtrW(h, -20, (ex & !0x00040000isize) | 0x80);
            // Explicit native tool window client dimensions; no normal caption/border or taskbar entry.
            let b = bounds.unwrap_or(Rect {
                x: p.x,
                y: p.y,
                w: (320. * w.scale_factor().unwrap_or(1.)).round() as i32,
                h: (367. * w.scale_factor().unwrap_or(1.)).round() as i32,
            });
            SetWindowPos(h, -1isize as *mut _, b.x, b.y, b.w, b.h, 0x30);
            let _ = size;
        }
    }
    #[cfg(not(windows))]
    let _ = (w, bounds);
}
fn foreground_inside(w: &tauri::Window) -> bool {
    #[cfg(windows)]
    {
        if let Ok(h) = w.hwnd() {
            unsafe {
                let foreground = GetForegroundWindow();
                return std::ptr::eq(foreground, h.0) || IsChild(h.0, foreground) != 0;
            }
        }
        false
    }
    #[cfg(not(windows))]
    {
        w.is_focused().unwrap_or(false)
    }
}
fn restore_window(w: &tauri::WebviewWindow) {
    let path = agentbar_collector::cli::default_database()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("state/dashboard.json");
    let state = std::fs::read(path)
        .ok()
        .and_then(|s| serde_json::from_slice::<Value>(&s).ok());
    let pos = state
        .as_ref()
        .and_then(|s| Some((s["x"].as_i64()? as i32, s["y"].as_i64()? as i32)))
        .unwrap_or((120, 80));
    let size = state
        .as_ref()
        .and_then(|s| Some((s["w"].as_i64()? as i32, s["h"].as_i64()? as i32)))
        .unwrap_or((1200, 860));
    if let Some(m) = w
        .monitor_from_point(pos.0 as f64, pos.1 as f64)
        .ok()
        .flatten()
        .or_else(|| w.primary_monitor().ok().flatten())
    {
        let a = m.work_area();
        let outer = w.outer_size().unwrap_or(PhysicalSize::new(1200, 860));
        let inner = w.inner_size().unwrap_or(outer);
        let dx = outer.width.saturating_sub(inner.width);
        let dy = outer.height.saturating_sub(inner.height);
        let client_width = a.size.width.saturating_sub(dx).max(1);
        let client_height = a.size.height.saturating_sub(dy).max(1);
        let _ = w.set_min_size(Some(PhysicalSize::new(
            ((640. * m.scale_factor()) as u32).min(client_width),
            ((480. * m.scale_factor()) as u32).min(client_height),
        )));
        let p = geometry::visible(
            Rect {
                x: pos.0,
                y: pos.1,
                w: size.0,
                h: size.1,
            },
            Rect {
                x: a.position.x,
                y: a.position.y,
                w: client_width as i32,
                h: client_height as i32,
            },
        );
        let _ = w.set_size(PhysicalSize::new(p.w as u32, p.h as u32));
        let _ = w.set_position(PhysicalPosition::new(p.x, p.y));
    }
}
fn save_window(w: &tauri::Window) {
    if let (Ok(p), Ok(s)) = (w.outer_position(), w.inner_size()) {
        if let Ok(db) = agentbar_collector::cli::default_database() {
            let root = db.parent().unwrap().parent().unwrap().join("state");
            let _ = std::fs::create_dir_all(&root);
            let _ = std::fs::write(
                root.join("dashboard.json"),
                serde_json::to_vec(&json!({"x":p.x,"y":p.y,"w":s.width,"h":s.height})).unwrap(),
            );
        }
    }
}
pub fn run() {
    if tauri::webview_version().is_err() {
        #[cfg(windows)]
        unsafe {
            #[link(name = "user32")]
            extern "system" {
                fn MessageBoxW(
                    h: *mut std::ffi::c_void,
                    text: *const u16,
                    title: *const u16,
                    flags: u32,
                ) -> i32;
            }
            let text="AgentBarBar requires Microsoft Edge WebView2 Runtime. Install the official Runtime, then start AgentBarBar again.".encode_utf16().chain(Some(0)).collect::<Vec<_>>();
            let title = "AgentBarBar — WebView2 unavailable"
                .encode_utf16()
                .chain(Some(0))
                .collect::<Vec<_>>();
            MessageBoxW(std::ptr::null_mut(), text.as_ptr(), title.as_ptr(), 0x10);
        }
        return;
    }
    let start = Instant::now();
    let builder =
        tauri::Builder::default().plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            let a = app.clone();
            let _ = app.run_on_main_thread(move || show_dashboard(&a, false));
        }));
    #[cfg(not(feature = "qa"))]
    let builder = builder.invoke_handler(tauri::generate_handler![
        business_request,
        window_action,
        popup_layout,
        front_ready
    ]);
    #[cfg(feature = "qa")]
    let builder = builder.invoke_handler(tauri::generate_handler![
        business_request,
        window_action,
        popup_layout,
        front_ready,
        qa_result
    ]);
    let application = builder
        .setup(move |app| {
            app.manage(PopupLayout(std::sync::Mutex::new(367.)));
            app.manage(ExitState {
                stopping: AtomicBool::new(false),
                done: AtomicBool::new(false),
            });
            let runtime = Runtime::start(app.handle().clone()).map_err(|_| {
                std::io::Error::other("AgentBarBar local database initialization failed")
            })?;
            app.manage(runtime);
            TrayIconBuilder::with_id("agentbarbar")
                .icon(tauri::image::Image::from_bytes(
                    crate::tray_appearance::icon_bytes(),
                )?)
                .tooltip("AgentBarBar")
                .menu(&menu(app.handle())?)
                .show_menu_on_left_click(false)
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_popup(tray.app_handle(), true)
                    }
                })
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_popup(app, false),
                    "settings" => show_dashboard(app, true),
                    "quit" => app.exit(0),
                    _ => (),
                })
                .build(app)?;
            let a = app.handle().clone();
            app.listen("settings_changed", move |_| {
                if let Some(t) = a.tray_by_id("agentbarbar") {
                    if let Ok(m) = menu(&a) {
                        let _ = t.set_menu(Some(m));
                    }
                }
            });
            // Minimal boot proves real WebView2 and shared dashboard, initially hidden for tray-first use.
            build_window(app.handle(), "dashboard", false)?;
            record(
                app.handle(),
                "tray_ready",
                json!({"elapsedMs":start.elapsed().as_millis()}),
            );
            #[cfg(feature = "qa")]
            qa_loop(app.handle().clone());
            Ok(())
        })
        .on_window_event(|w, event| match event {
            WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                if w.label() == "dashboard" {
                    save_window(w)
                }
                let _ = w.hide();
                record(w.app_handle(), "window_hidden", json!({"window":w.label()}));
            }
            WindowEvent::Focused(false) if w.label() == "popup" => {
                let inside = foreground_inside(w);
                record(
                    w.app_handle(),
                    "popup_focus_changed",
                    json!({"foregroundInside":inside,"visible":w.is_visible().unwrap_or(false)}),
                );
                if !inside {
                    let _ = w.hide();
                }
            }
            WindowEvent::ThemeChanged(theme) => {
                let a = w.app_handle();
                crate::tray_appearance::refresh(a);
                let _ = a.emit(
                    "system_theme_changed",
                    json!({"dark":*theme==tauri::Theme::Dark}),
                );
            }
            _ => (),
        })
        .build(tauri::generate_context!())
        .expect(
            "AgentBarBar initialization failed; see local logs and WebView2 Runtime availability",
        );
    application.run(|app, event| {
        if let RunEvent::ExitRequested { api, .. } = event {
            let state = app.state::<ExitState>();
            if !state.done.load(Ordering::Acquire) {
                api.prevent_exit();
                if !state.stopping.swap(true, Ordering::AcqRel) {
                    let a = app.clone();
                    let r = app.state::<Arc<Runtime>>().inner().clone();
                    std::thread::spawn(move || {
                        r.stop();
                        record(&a, "graceful_shutdown", json!({"checkpoint":"committed"}));
                        a.remove_tray_by_id("agentbarbar");
                        a.state::<ExitState>().done.store(true, Ordering::Release);
                        a.exit(0);
                    });
                }
            }
        }
    });
}
#[cfg(feature = "qa")]
fn qa_loop(app: tauri::AppHandle) {
    std::thread::spawn(move || {
        let root = agentbar_collector::cli::default_database()
            .unwrap()
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("state");
        let mut last = String::new();
        loop {
            std::thread::sleep(std::time::Duration::from_millis(200));
            if app.state::<ExitState>().stopping.load(Ordering::Acquire) {
                break;
            }
            let request = std::fs::read_to_string(root.join("qa-command.json")).unwrap_or_default();
            if request == last {
                continue;
            }
            last = request.clone();
            let q: Value = match serde_json::from_str(&request) {
                Ok(q) => q,
                Err(_) => continue,
            };
            let a = app.clone();
            let _=app.run_on_main_thread(move||{match q["action"].as_str().unwrap_or(""){"popup"=>show_popup(&a,false),"dashboard"=>show_dashboard(&a,false),"settings"=>show_dashboard(&a,true),"hide-popup"=>{if let Some(w)=a.get_webview_window("popup"){let _=w.hide();}},"hide-dashboard"=>{if let Some(w)=a.get_webview_window("dashboard"){let _=w.hide();}},"quit"=>a.exit(0),"preferences"=>{let mut value=prefs(&a);for key in ["language","dashboardTheme","dashboardAppearance"]{if let Some(v)=q.get(key){value[key]=v.clone();}}let (tx,_)=std::sync::mpsc::sync_channel(1);let _=a.state::<Arc<Runtime>>().sender.try_send(Work::Settings(value,tx));},"dom"=>{for w in a.webview_windows().values(){let _=w.eval("window.__TAURI__.core.invoke('qa_result',{result:{label:document.title,ready:document.querySelectorAll('.error-box').length===0,text:document.querySelector('main')?.innerText?.slice(0,2000)||document.getElementById('root')?.innerText?.slice(0,2000),theme:document.documentElement.dataset.theme,appearance:document.documentElement.dataset.appearance,lang:document.documentElement.lang,viewport:[innerWidth,innerHeight],scale:devicePixelRatio}})");}},_=>()};record(&a,"qa_action_completed",json!({"action":q["action"],"sequence":q["sequence"]}));});
        }
    });
}

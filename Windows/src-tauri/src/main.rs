#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod app;
mod runtime;
mod tray_appearance;
fn main() {
    app::run();
}

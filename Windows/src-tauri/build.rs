fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(
        tauri_build::WindowsAttributes::new().app_manifest(include_str!("app.manifest")),
    ))
    .expect("AgentBarBar build metadata failed");
}

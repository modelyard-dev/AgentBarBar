# Windows development

Build and test the Windows host on a native Windows machine. A macOS or Linux build does not replace Windows validation.

## Requirements

- 64-bit Windows with the WebView2 Runtime.
- Rust 1.94.1 with the MSVC target and Visual Studio Build Tools C++ workload.
- Node.js 24 and npm.
- Tauri CLI v2 on `PATH` for packaging; NSIS is required by the installer packaging scripts.

## Build and test

Run PowerShell from the repository root:

```powershell
cd Dashboard
npm ci
npm run build
cd ..
cargo test --locked --workspace --manifest-path Shared/core/Cargo.toml
cargo test --locked --manifest-path Windows/src-tauri/Cargo.toml
cargo build --release --locked --manifest-path Windows/src-tauri/Cargo.toml
```

The generated release executable is under `Windows/src-tauri/target/release/`. GitHub Actions runs the Rust tests on Windows and the dashboard checks on macOS.

## Package an installer

Use a new version/build for a release candidate, build the Windows executable, then run the packaging script with the target directory and Tauri CLI path:

```powershell
pwsh -NoProfile -File .\Windows\packaging\package-release.ps1 `
  -SourceRoot $PWD `
  -TargetDir (Join-Path $PWD 'Windows\src-tauri\target') `
  -TauriCli tauri.cmd
```

The script generates a bilingual current-user NSIS installer, SHA-256 file, and build manifest. The installer is unsigned by default. Keep package outputs under `build/` and upload them as release assets; do not commit them.

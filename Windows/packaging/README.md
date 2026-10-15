# Windows build and packaging

The Windows host is built from `Windows/src-tauri` and uses the shared Rust crates in `Shared/core`. See [Windows development](../../docs/windows-development.md) for prerequisites and build commands.

## NSIS packaging

`package-release.ps1` bundles a previously built Windows release binary, applies the bilingual installer patches, and writes the installer, checksum, and build manifest under the selected output directory. It does not sign the installer.

```powershell
pwsh -NoProfile -File .\Windows\packaging\package-release.ps1 `
  -SourceRoot $PWD `
  -TargetDir <cargo-target-directory> `
  -TauriCli tauri.cmd
```

`TargetDir` must contain `release\AgentBarBar.exe` and the generated NSIS installer tree. If the Tauri CLI is not on `PATH`, pass its executable path with `-TauriCli`. The two NSIS patch scripts reject unexpected installer templates and should run once on a newly generated installer script.

The packaged installer is a release artifact, not a Git file. Keep installers, checksums generated from local builds, and build outputs out of commits.

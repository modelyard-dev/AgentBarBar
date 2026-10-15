# Release workflow

macOS and Windows versions/build numbers advance independently. The root `VERSION` and `BUILD_NUMBER` files configure macOS; `Windows/src-tauri/tauri.conf.json` and `Windows/BUILD_NUMBER` configure Windows.

## Before a release

1. Confirm the platform, version, build number, release channel, and tested source commit.
2. Run the platform's native checks. Cross-platform code changes require checks on every affected platform.
3. Review all collector changes against the source support matrix and anonymous fixtures.
4. Confirm `CHANGELOG.md` has a platform-specific entry with actual versions/builds, timestamp, details, and verification limits.
5. Build the platform installer, review its privacy/audit output, and calculate a SHA-256 checksum.
6. Keep installers and machine-specific validation data out of Git. Publish installers as release attachments with a public, sanitized validation summary.

## Tags and artifacts

Use `macos-v<version>` and `windows-v<version>` for platform release tags. Internal candidates use an `-internal` suffix and prerelease status. Do not move an existing published tag to a different commit. Installer binaries (`.dmg`, `.exe`, `.msi`) belong in release attachments rather than repository history.

A public validation summary should include only platform, product version/build, checks performed, checksums, signing state, and known validation limits. Do not publish local database sizes, machine/user identifiers, private source paths, raw logs, screenshots with usage data, or per-host file inventories.

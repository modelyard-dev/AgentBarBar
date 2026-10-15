# Development

## macOS

Requirements: macOS 14 or later, Xcode/Swift 6, and Node.js 24 for the dashboard.

From the repository root:

```bash
swift build
swift test
cd Dashboard
npm ci
npm run build
npm test
npx playwright install chromium
npm run test:e2e
```

`scripts/check.sh` runs the Swift, dashboard, and browser checks. `scripts/build_release_app.sh` creates a local `.app`; it does not install it. Use the version and install scripts only when intentionally preparing a new local build.

The CLI target is `agentbarbar-cli`:

```bash
swift run agentbarbar-cli --help
```

## Windows

See [Windows development](windows-development.md) for native prerequisites and commands.

## Shared Rust

Install the pinned Rust toolchain listed in `Shared/core/rust-toolchain.toml`. Run shared tests from the repository root:

```bash
cargo test --locked --workspace --manifest-path Shared/core/Cargo.toml
```

The Windows host crate has its own lockfile and manifest under `Windows/src-tauri/`; run it on Windows as documented in the Windows guide. Shared fixtures live in `Tests/Fixtures/` and contain anonymous metadata only.

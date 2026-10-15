# AgentBarBar

A local-first AI Agent usage monitor for macOS and Windows. AgentBarBar reads supported local usage metadata, stores a private local ledger, and presents it in a native menu-bar/tray app and a bundled dashboard.

[中文说明](README.zh-CN.md) · [Downloads](https://github.com/y2zyyr/AgentBarBar/releases/tag/v1.0.7) · [Documentation](docs/README.md) · [MIT License](LICENSE)

![AgentBarBar icon](assets/icon.png)

## Features

- Native macOS menu bar app and Windows tray app.
- Local dashboard with summaries, agents, models, projects, sessions, and source coverage.
- Versioned collectors for supported agent usage formats; availability varies by platform and upstream version.
- Nullable metrics and explicit coverage states. Missing or unsupported values are never presented as zero.
- Read-only source collection. Prompts, replies, conversation bodies, source code, and credentials are excluded from the usage ledger.
- Data stays on the device. The macOS update checker can contact GitHub Releases; it does not send collected usage data.

See the [source support matrix](docs/source-support.md) for collector scope and the [privacy notes](docs/data-and-privacy.md) for storage and network behavior. Claude Code CLI and the Claude Desktop Code tab share a supported local request stream. Claude Desktop standard chat and Cowork do not currently have a verified request-level usage source and are excluded from totals.

## Download

The public [AgentBarBar 1.0.7 release](https://github.com/y2zyyr/AgentBarBar/releases/tag/v1.0.7) contains the macOS 1.0.7/build38 and Windows 1.0.7/build39 installers. macOS distribution is for Apple Silicon and macOS 14 or later. The Windows installer targets 64-bit Windows. Read the release notes for signing and validation limits.

## Build from source

Requirements and platform-specific commands are in [Development](docs/development.md). In brief:

```bash
swift test
cd Dashboard
npm ci
npm run build
npm test
```

Windows build and test commands are documented separately in [Windows development](docs/windows-development.md). GitHub Actions runs the macOS and Windows source checks.

## Repository layout

- `Sources/` — native macOS app, shared Swift core, and CLI.
- `Windows/` — native Windows Tauri host and installer tooling.
- `Shared/` — Rust core, usage-event schema, and database migrations.
- `Dashboard/` — shared React/TypeScript dashboard.
- `Tests/Fixtures/` — anonymous metadata fixtures used by shared Rust contract tests.

The repository contains source and anonymous test metadata, not user databases, transcripts, local build outputs, or installers. See [Contributing](CONTRIBUTING.md) before changing collectors or fixtures.

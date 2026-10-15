# AgentBarBar for Windows

[简体中文](WINDOWS.zh-CN.md) · [Download the x64 installer](https://github.com/y2zyyr/AgentBarBar/releases/download/v1.0.7/AgentBarBar-1.0.7-Windows-x64-Setup.exe)

AgentBarBar runs from the Windows notification area and opens its bundled dashboard in a local WebView. The installer targets 64-bit Windows and installs for the current user.

## Install

1. Download the x64 setup file from the [1.0.7 release](https://github.com/y2zyyr/AgentBarBar/releases/tag/v1.0.7).
2. Close AgentBarBar from its tray menu before replacing an existing installation.
3. Run the installer. Administrator privileges are not normally required.
4. Start AgentBarBar from the Start menu or desktop shortcut, then select its tray icon to open the dashboard.

The app requires the WebView2 Runtime. The installer can download Microsoft's Evergreen bootstrapper if the runtime is missing, which may require an internet connection. Rust, Node.js, and Visual Studio are build-time dependencies only.

The current installer is unsigned. SHA-256 verifies file integrity, not publisher identity. The expected checksum is published beside the installer in the release assets.

## Data and support

Usage data is stored under the current Windows user's local application data directory. Collectors read supported Agent metadata locally and do not upload usage history. Do not attach databases, Agent logs, credentials, or screenshots with usage data to support requests.

Collector availability depends on the installed Agent version and local source files. See the [collector support matrix](docs/source-support.md). Claude Desktop standard chat and Cowork are not included in usage totals because no request-level local usage source is verified.

For development and packaging, see [Windows development](docs/windows-development.md).

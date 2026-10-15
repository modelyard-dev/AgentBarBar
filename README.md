<p align="center"><img src="assets/icon.png" width="100" alt="AgentBarBar"></p>
<h1 align="center">AgentBarBar</h1>
<p align="center">Your AI usage, at a glance.</p>
<p align="center"><a href="README.zh-CN.md">简体中文</a> · <a href="README.md">English</a></p>
<p align="center"><a href="https://github.com/y2zyyr/AgentBarBar/releases/latest"><strong>Download for macOS →</strong></a> · <a href="https://github.com/y2zyyr/AgentBarBar/releases/download/v1.0.7/AgentBarBar-1.0.7-Windows-x64-Setup.exe"><strong>Download for Windows →</strong></a></p>
<p align="center">macOS 1.0.7 · Windows 1.0.7/build39 · Apple Silicon · macOS 14+ · 中文 / English</p>

<p align="center"><a href="https://github.com/y2zyyr/AgentBarBar/releases/latest"><img src="assets/poster-en.png" width="680" alt="AgentBarBar promotional poster"></a></p>

![AgentBarBar usage overview](assets/overview-en.png)
<p align="center"><sub>Demo data</sub></p>

<p align="center"><img src="assets/popover-en.png" width="330" alt="Menu bar preview · Demo data"></p>
<p align="center"><sub>Menu bar preview · Demo data</sub></p>

## Know what you use

AgentBarBar tracks local AI Agent usage from the macOS menu bar or Windows system tray. See today's tokens, recent trends and usage by Agent in one place.

- **A quick glance** — Today's token total in the menu bar, with your leading Agents one click away.
- **Clear trends** — Switch between today, 7 days, 30 days and all time.
- **One place** — Local usage totals, request details and exports for supported Agents.
- **Your own look** — Four themes, each with light, dark and system modes.
- **Private on your device** — No telemetry uploads or stored conversation bodies.

## Four ways to make it yours

Choose **Forest, Paper, Ocean or Mono** in **Dashboard Settings → Appearance**. Preview each style, choose light/dark or follow your system, and switch instantly. Your choice is saved automatically.

<table>
<tr>
<td width="50%" align="center"><strong>Forest · Dark</strong><br><a href="assets/theme-forest-en.png"><img src="assets/theme-forest-en.png" width="480" alt="Forest · Dark · Demo data"></a></td>
<td width="50%" align="center"><strong>Paper · Light</strong><br><a href="assets/theme-paper-en.png"><img src="assets/theme-paper-en.png" width="480" alt="Paper · Light · Demo data"></a></td>
</tr>
<tr>
<td width="50%" align="center"><strong>Ocean · Dark</strong><br><a href="assets/theme-ocean-en.png"><img src="assets/theme-ocean-en.png" width="480" alt="Ocean · Dark · Demo data"></a></td>
<td width="50%" align="center"><strong>Mono · Light</strong><br><a href="assets/theme-mono-en.png"><img src="assets/theme-mono-en.png" width="480" alt="Mono · Light · Demo data"></a></td>
</tr>
</table>

<p align="center"><sub>Theme previews · Demo data</sub></p>

![Theme and color-mode settings](assets/appearance-en.png)
<p align="center"><sub>Settings → Appearance · Demo data</sub></p>

## Install on macOS

1. [Download the latest DMG](https://github.com/y2zyyr/AgentBarBar/releases/latest) and drag the app to **Applications**.
2. Open the app, then click its menu bar icon to view usage.

![Bilingual installation window](assets/install.png)

If macOS cannot verify the developer, try opening the app, then go to **System Settings → Privacy & Security → Open Anyway**. The current download is not notarized by Apple.

## Windows 1.0.7 / build39

[Download the Windows x64 installer](https://github.com/y2zyyr/AgentBarBar/releases/download/v1.0.7/AgentBarBar-1.0.7-Windows-x64-Setup.exe) · [Windows installation guide and limitations](WINDOWS.md)

Windows Setup SHA-256: `6f1cccdad3df3f5d9238ce6ae53b8b7e2fd04386bd2fb2bf9daf51e01a1e11ff`. The installer is unsigned.

A real system-tray app with a quick usage popup and the shared dashboard: Today, 7 days, 30 days, all time, Agent/model breakdowns and request details. Forest, Paper, Ocean and Mono; light/dark/system modes; Chinese and English.

- **Twelve collectors:** Codex, Claude Code, Kimi CLI, DeepSeek Harness, WorkBuddy, Pi, Gemini CLI, OpenCode, Antigravity, Antigravity IDE, Qwen Code and Cline (legacy tasks). Windows and macOS now ship the same adapter set.
- **Claude Desktop:** The Code tab shares the Claude Code stream; standard chat and Cowork remain inspection-only and do not contribute Token usage until a request-level local source is verified.
- **Validated with real Windows sources:** Codex, Claude Code, Kimi historical records and DeepSeek Harness. DSH uses its canonical SQLite ledger, with aggregate reconciliation and replay deduplication.
- **Fixture validation:** all twelve collectors match the macOS reference for request identities and token values/states. Agents without usable records on the validation host have not received real-source system validation.
- **Source survey:** finds candidate Token fields, reconciles the selected collector and restores saved reports after reload. History coverage shows retained record counts and dates, including unchanged scans.
- **Source tracing:** Gemini records keep their real source line and byte positions, and the shared cursor format is now `gemini-session-v2.0.1`. Missing counters stay unavailable instead of being shown as zero.
- **Sync feedback:** completion replaces the “Sync started” notice, including a sync with no new records.
- **Link handling:** the Tibo Codex Monitor link is handed to the native window action and opens fixed HTTPS resources in your system default browser, with a visible message when it fails.
- **Installation:** Chinese and English appear together on each installer page. The package is unsigned; Windows autostart and automatic updates are not implemented. A newer build of the same app version can be installed over an existing copy, build downgrades are refused, and the previous app is backed up.

Tested on Windows 11 x64 with WebView2. No Rust, Node.js or development tools are required to run the installed app. Quit AgentBarBar from its tray menu before installing over an existing copy.

![Windows dashboard](assets/windows/dashboard-en.png)
<p align="center"><img src="assets/windows/popup-en-dark.png" width="320" alt="Windows tray popup"></p>
<p align="center"><sub>Actual Windows app captures from pre-packaging validation; usage totals only, no conversation content. These are not screenshots of the final rebuilt installer.</sub></p>

![Windows installer welcome](assets/windows/install-zh.png)
<p align="center"><sub>Actual bilingual 1.0.4 installer capture; the 1.0.7 package preserves this layout.</sub></p>

## Supported Agents

On macOS and Windows, reads local usage records from Codex, Claude Code, DeepSeek Harness, WorkBuddy, Pi, Kimi CLI, Gemini CLI, OpenCode, Antigravity, Antigravity IDE, Qwen Code and Cline (legacy tasks).

Available metrics depend on the records an Agent provides. Missing counters remain unavailable. Importing a large history for the first time may take a few minutes.

On macOS 1.0.7, Claude Code CLI and the Claude Desktop Code tab share one local request stream and are attributed without duplicate counting. Claude Desktop standard chat and Cowork have bounded local metadata inspection only; no Token usage is counted until a request-level source is verified.

On Windows 1.0.7/build39, the Code tab uses the same Claude Code stream. The validation host had no Claude Desktop executable; a bounded survey checked 35 files / 83,835 bytes, found no candidate Token fields and reached a scan limit. Standard chat/Cowork remain excluded; this does not rule out every upstream format.

## Updates & feedback

The macOS app checks GitHub for new versions and lets you download the installer. The DMG is saved to **Downloads** and opened; drag the app to **Applications** to replace your installed version. Automatic checks can be turned off in native settings.

The dashboard also links to [Tibo Codex Monitor](https://tibo.modelyard.dev), an independent tracker of Codex limit resets and policy updates.


- [Releases](https://github.com/y2zyyr/AgentBarBar/releases)
- [Report a bug / suggest a feature](https://github.com/y2zyyr/AgentBarBar/issues)

Please include your app version, operating-system version and Agent name. Chat logs and account credentials are not needed.

## Share AgentBarBar

[English poster](assets/poster-en.png) · [中文海报](assets/poster-zh.png)

## About this repository

This repository hosts product information and downloads. Application source code remains private. AgentBarBar is free to download and use; third-party license notices are included in the app.

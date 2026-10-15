# AgentBarBar

面向 macOS 和 Windows 的本地 AI Agent 用量监控工具。它只读取受支持的本地用量元数据，将记录保存在本机私有数据目录，并通过原生菜单栏/托盘应用和内置 Dashboard 展示。

[English](README.md) · [下载安装](https://github.com/y2zyyr/AgentBarBar/releases/tag/v1.0.7) · [文档索引](docs/README.md) · [MIT 许可证](LICENSE)

![AgentBarBar 图标](assets/icon.png)

## 功能

- macOS 原生菜单栏应用和 Windows 托盘应用。
- Dashboard 提供概览、Agent、模型、项目、会话和来源覆盖情况。
- 按版本解析受支持的本地 Agent 用量格式；实际可用性取决于平台和上游版本。
- 指标使用可空值和明确覆盖状态；缺失或不支持的数据不会显示成 0。
- 只读采集。提示词、回复、对话正文、源代码和凭据不会写入用量账本。
- 数据留在设备本地。macOS 更新检查可能访问 GitHub Releases，但不会发送已采集的用量数据。

查看[来源支持矩阵](docs/source-support.md)了解采集器范围，查看[隐私与存储说明](docs/data-and-privacy.md)了解数据和网络行为。Claude Code CLI 与 Claude Desktop 的 Code 标签页共用受支持的本地请求流。Claude Desktop 普通聊天和 Cowork 暂无已验证的请求级用量来源，因此不计入统计。

## 下载

公开的 [AgentBarBar 1.0.7 Release](https://github.com/y2zyyr/AgentBarBar/releases/tag/v1.0.7) 提供 macOS 1.0.7/build38 和 Windows 1.0.7/build39 安装包。macOS 安装包适用于 Apple Silicon 和 macOS 14 或更新版本；Windows 安装包面向 64 位 Windows。签名和验证限制请查看 Release 说明。当前源码快照见 [macOS 1.0.7 标签](https://github.com/y2zyyr/AgentBarBar/tree/macos-v1.0.7)和 [Windows 1.0.7 标签](https://github.com/y2zyyr/AgentBarBar/tree/windows-v1.0.7)；两个标签指向同一份跨平台源码提交。

## 从源码构建

依赖与平台命令见[开发指南](docs/development.md)。macOS 基本检查命令：

```bash
swift test
cd Dashboard
npm ci
npm run build
npm test
```

Windows 构建与检查命令见[Windows 开发指南](docs/windows-development.md)。GitHub Actions 会分别运行 macOS 和 Windows 源码检查。

## 仓库结构

- `Sources/` — macOS 原生应用、Swift 共用核心和 CLI。
- `Windows/` — Windows 原生 Tauri 主机与安装包工具。
- `Shared/` — Rust 核心、用量事件 Schema 和数据库迁移。
- `Dashboard/` — React/TypeScript 共用 Dashboard。
- `Tests/Fixtures/` — Rust 共用契约测试使用的匿名元数据样例。

仓库包含源码和匿名测试元数据，不包含用户数据库、对话记录、本机编译产物或安装包。修改采集器或 fixtures 前请先读[贡献指南](CONTRIBUTING.md)。

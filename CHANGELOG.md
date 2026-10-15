# Changelog

This public changelog records source releases and public documentation updates. Binary release history is available in the [GitHub Releases](https://github.com/y2zyyr/AgentBarBar/releases) page.

## [macOS / Windows（共用）1.0.7] — 首次公开源码与文档整理

- **时间戳：** 2026-10-15 22:54:34 +08:00。
- **平台：** macOS / Windows（共用）。
- **版本号：** macOS 1.0.7/build38；Windows 1.0.7/build39。公开源码快照，两个安装包版本均未升版。
- **更新详情：** 在 GitHub 加入 macOS、Windows、共享 Rust 和 Dashboard 源码，采用 MIT 许可证；重整中英文项目说明、开发、隐私、架构、来源支持和发布文档。共享契约 fixtures 移至 `Tests/Fixtures/`。清理当前公开树和 Windows Release 摘要中的本机用量截图、数据库大小、文件清单和运行时数据；不改动现有 `v1.0.7` 发布标签与安装包。
- **验证结果：** macOS Swift 73 项、共享 Rust 75 项、Dashboard 构建、11 项单测和 23 项 Playwright 检查通过；候选源码敏感信息扫描未发现本机用户名/路径、内网地址、凭据或私钥，未包含数据库、安装包或内部发布证据。Windows 原生测试由新建的 GitHub Actions 作业执行；推送前尚未运行该作业。

## [Windows 1.0.7/build39] — 修复 Windows 图标资源格式

- **时间戳：** 2026-10-15 23:03:28 +08:00。
- **平台：** Windows。
- **版本号：** Windows 1.0.7/build39 源码构建；macOS 1.0.7/build38 未更新，未重打安装包、未升版。
- **更新详情：** 将 Windows `.ico` 改为包含多分辨率 PNG 帧的 ICO，避免 Windows SDK 资源编译器因旧 DIB 帧报 RC2176；为 `.ico`、`.png` 和 `.zstd` 增加二进制行尾保护，并恢复 Windows PNG 图标原始字节；开发文档注明后续替换图标时保留该编码。
- **验证结果：** 首次 GitHub Windows 作业在资源编译阶段因 RC2176 失败；图标已修复，Windows 原生重跑等待 GitHub Actions。macOS、共享 Rust、Dashboard 和 Playwright 在首次作业中均通过。

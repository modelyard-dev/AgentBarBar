# AgentBarBar Windows — 1.0.7/build39

[English](WINDOWS.md) · [下载安装包](https://github.com/y2zyyr/AgentBarBar/releases/download/v1.0.7/AgentBarBar-1.0.7-Windows-x64-Setup.exe)

Windows x64 系统托盘应用，版本 1.0.7（构建 39）。安装标题、说明和按钮在每一页同时显示中文和 English。

## 安装和使用

1. 覆盖安装前，先从系统托盘菜单退出当前 AgentBarBar。
2. 下载并运行 x64 安装包，安装到当前 Windows 用户目录；正常使用无需管理员权限。已验证 Windows 11 x64，ARM64 和较旧 Windows 尚未确认。
3. 需要 WebView2；缺失时安装包配置为下载 Evergreen 引导程序，此时可能需要网络。Runtime 缺失或损坏场景尚未完整验证。
4. 从桌面或开始菜单启动。点击通知区域图标查看今日用量，再点击“打开仪表盘”查看完整统计。
5. 在设置中切换中文 / English、松绿 / 纸感 / 深海 / 极简和浅色 / 深色 / 跟随系统。关闭仪表盘仅隐藏窗口；托盘菜单“退出”才会退出应用。

运行无需 Rust、Cargo、Node.js 或 Visual Studio。

## 采集器

| Agent | 验证情况 |
|---|---|
| Codex | Windows 真实数据源采集已验证 |
| Claude Code | Windows 真实数据源采集已验证 |
| Kimi CLI | Windows 真实历史记录已验证；实时计数仍为部分验证 |
| DeepSeek Harness | Windows 真实 SQLite 用量账本独立核对通过；重复同步不会重复计数 |
| Qwen Code | 已解析版本化月度 Token 账本，按账本记录 ID 去重；验证机器没有可用数据，仅完成样本验证 |
| Cline（旧版任务） | 合并 `ui_messages.json` 中同一请求的开始 / 结束记录；验证机器没有可用数据，仅完成样本验证 |
| WorkBuddy、Pi、Gemini CLI、OpenCode、Antigravity、Antigravity IDE | 已实现并通过与 macOS 的匿名样本对照；验证机器没有可用数据，尚未完成真实数据源系统验证 |

## Claude 来源

Claude Code CLI 与 Claude Desktop Code 标签页共用 `.claude/projects` 请求记录；解析器保留来源上报的 entrypoint，并按稳定请求身份去重。普通聊天与 Cowork 仅做 inspection-only 勘测，因为尚无已验证的本地请求级 Token 来源。Windows 验证主机未检测到 Claude Desktop 可执行程序；有界 survey 检查 35 个文件 / 83,835 字节，未发现候选 Token 字段，但扫描达到边界，因此仍不统计普通聊天/Cowork 用量。

十二个采集器均可配置来源路径和启用开关。缺失的数据源或计数显示为不可用；读取本机记录无需 API Key。DSH 使用一个权威账本，支持排除记录和调低计数的账务修正，不会把会话日志再次叠加到账本总数。

Windows 的“自动勘测 Token 来源”已接入，可保存只含元信息的报告，重载后仍能查看。历史覆盖按已保存记录数和日期范围显示；本次新增 0 条不再误显示为历史记录 0 条。

手动同步结束后显示“同步已完成”，没有新增记录也会正确结束。首次导入大量历史记录可能需要较长时间。

Gemini 记录现已保留真实来源行号和字节位置，共享游标格式为 `gemini-session-v2.0.1`，已有来源文件按新格式重放。托盘应用中的 Tibo Codex Monitor 链接交由系统默认浏览器打开；仅固定 HTTPS 资源会交给系统浏览器，失败时会显示提示。

## 数据与卸载

程序默认位于 `%LOCALAPPDATA%\Programs\AgentBarBar`；数据独立位于 `%LOCALAPPDATA%\AgentBarBar`，数据库为 `database\usage.sqlite`。

应用仍在运行时，安装程序会拒绝覆盖。普通卸载设计为保留用量数据；只有主动勾选删除数据选项才会删除。本次保留既有的数据保护逻辑；更新后安装包的最终卸载 / 删除数据及完整升级回滚尚未完成验证。此前内部 1.0.5 / 1.0.6 的降级路径也尚未验证。

## 校验与当前限制

安装包**未签名**。SHA256 用于文件完整性校验，不代表发布者身份认证。

```powershell
Get-FileHash .\AgentBarBar-1.0.7-Windows-x64-Setup.exe -Algorithm SHA256
```

SHA256：`6f1cccdad3df3f5d9238ce6ae53b8b7e2fd04386bd2fb2bf9daf51e01a1e11ff`。

暂不提供 Windows 登录自动启动和自动更新。长期运行、睡眠恢复、Explorer 恢复、物理多屏 / 混合 DPI 和完整升级回滚验证尚未完成；后续更新请从 GitHub 手动下载。

统计留在本机，不上传对话正文或遥测。反馈只需应用 / 系统版本和 Agent 名称，无需提交私密日志或凭据。

## 截图来源

README 的 Windows 图片来自此前的真实应用截图。双语安装图展示 1.0.4 安装包的布局，1.0.7 安装包保留该布局；它不是更新后程序的新截图。

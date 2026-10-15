# AgentBarBar Windows

[English](WINDOWS.md) · [下载 64 位安装包](https://github.com/y2zyyr/AgentBarBar/releases/download/v1.0.7/AgentBarBar-1.0.7-Windows-x64-Setup.exe)

AgentBarBar 在 Windows 通知区域运行，并通过本地 WebView 打开内置 Dashboard。安装包面向 64 位 Windows，默认安装到当前用户。

## 安装

1. 从 [1.0.7 Release](https://github.com/y2zyyr/AgentBarBar/releases/tag/v1.0.7) 下载 x64 安装包。
2. 覆盖现有安装前，从托盘菜单退出 AgentBarBar。
3. 运行安装程序。通常不需要管理员权限。
4. 从开始菜单或桌面快捷方式启动，再点击托盘图标打开 Dashboard。

应用需要 WebView2 Runtime。缺失时，安装程序可以下载 Microsoft Evergreen 引导程序，因此可能需要联网。Rust、Node.js 和 Visual Studio 仅用于构建。

当前安装包未签名。SHA-256 只能校验文件完整性，不能认证发布者身份。预期校验和与安装包一同发布。

## 数据与支持

用量数据保存在当前 Windows 用户的本地应用数据目录。采集器只在本机读取受支持 Agent 的元数据，不上传用量历史。请勿在反馈中附带数据库、Agent 日志、凭据或包含用量数据的截图。

采集器可用性取决于已安装的 Agent 版本和本机来源文件。查看[采集器支持矩阵](docs/source-support.md)。由于尚无已验证的请求级本地用量来源，Claude Desktop 普通聊天和 Cowork 不计入统计。

构建和打包说明见 [Windows 开发指南](docs/windows-development.md)。

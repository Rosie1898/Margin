# Margin for Mac 0.5.3 and Windows 0.5.2

This release publishes the current Mac and Windows applications together.

- Both apps include OCR language selection, seven interface themes, and system sans-serif text.
- Settings now includes Personalization. Instructions are saved locally and included with every question and follow-up. Edits apply to the next request, including in existing conversations.
- On Mac, the ChatGPT Keychain item name follows the system language. Existing items are renamed after authorized access.

Download `Margin-0.5.3-macOS-arm64.zip` for macOS 14 or later on Apple Silicon. Unzip it and move `Margin.app` into Applications. Download `Margin-0.5.2-Windows-x64-Setup.exe` for Windows 10 or 11 on x64. Both downloads include their runtime. `SHA256SUMS.txt` contains the file checksums.

The Mac build is ad-hoc signed and has not been notarized. The Windows installer has no purchased code-signing certificate. User data stays in the existing platform data directory.

Release checks passed for all 36 Mac backend tests, nine native suites, and three local installer tests. The Windows suite passed 79 tests on Mac, with four Windows-only checks skipped. The saved Windows 0.5.2 validation records report 83 passing tests and 11 installed-app UI checks. All 87 Windows runtime source and asset files match the packaged application, and the installer matches its recorded SHA-256. These checks use simulated account responses and do not verify live ChatGPT sign-in or model replies.

本次同时发布当前 Mac 0.5.3 和 Windows 0.5.2。

- 两端均支持 OCR 语言选择、七种界面主题和系统无衬线字体。
- 设置新增“个性化”。指令保存在本机，每次提问与追问都会附带，修改从下一次请求起生效，已有讨论同样适用。
- Mac 的 ChatGPT 钥匙串条目名称跟随系统语言，已有条目在授权访问后更新名称。

Mac 请选择 `Margin-0.5.3-macOS-arm64.zip`，要求 macOS 14 或更新版本与 Apple Silicon。解压后将 `Margin.app` 放入“应用程序”。Windows 请选择 `Margin-0.5.2-Windows-x64-Setup.exe`，适用于 Windows 10/11 x64。两端均包含运行时，文件校验值见 `SHA256SUMS.txt`。

Mac 采用 ad-hoc 签名，尚未进行 Apple 公证；Windows 安装包没有购买的代码签名证书。用户数据沿用原有平台资料目录。测试使用模拟账号响应，真实 ChatGPT 登录和模型回复尚未验证。

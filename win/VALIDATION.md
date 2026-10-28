# Windows 版本验证

## 0.5.2 个性化指令（2026-10-27）

设置新增「个性化」输入栏，沿用 `mac/current` 的九语言文案。指令自动保存；每轮提问和追问都将当前内容放入模型请求的 `instructions`，与 PDF 参考文字和历史消息分开。修改和清空从下次发送生效。超过 16,000 个 UTF-16 字符时保留完整草稿并阻止发送。

- `node scripts/run-tests.mjs`：83/83 通过。包括多行指令保存与重启恢复、每轮实际出站请求体、修改/清空/切换模型、请求去重，以及 Windows 对话文件短暂独占锁的原子写入重试。
- `MARGIN_INSTALLED=1 node scripts/test-chat-ui.mjs`：已安装的 0.5.2 通过 11 组界面检查，使用独立测试资料和明确的模拟聊天响应。覆盖输入保存、页面重新加载、超长拦截、追问采用最新指令、清空后停用，以及现有讨论流程。
- `node scripts/build.mjs`：已升级 `C:\Program Files\Margin` 原有全用户安装，保留安装范围与用户数据，7 个安装文件哈希核验成功。另核对本次 7 个运行源码文件与打包内容完全一致，安装的 `app.asar` 与打包版一致。

证据：`test-results/personalization-validation.json`、`test-results/installed-chat-ui-result.json`、`test-results/local-install-result.json`；截图：`test-results/installed-chat-ui-personalization.png`。本次未调用真实模型；验证的是逐轮请求中包含正确指令，不代表模型对所有要求的遵循质量测试。

## 以下为 0.5.1 的历史验证记录

验证日期：2026-10-26。Windows 版本：0.5.1。环境：Windows 11 x64，Electron 45.0.0。Mac 的 OCR 语言菜单、主题和字体同步修改了源码；当前环境没有 macOS SDK，Mac 新版二进制尚未构建或运行验证。

## 已执行并通过

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 账号/聊天后端、OCR 服务、资料库自动化测试 | 79/79 通过 | `test-results/unit-tests.txt` |
| 真实 Electron DPAPI 与系统 OCR | 9 项通过 | `test-results/native-electron-result.json` |
| 最终打包程序的阅读与 OCR 界面流程 | 14 组通过 | `test-results/packaged-ui-result.json` |
| 最终打包程序的 AI 界面及快速文档切换 | 8 组通过，使用明确的模拟聊天服务 | `test-results/packaged-chat-ui-result.json` |
| 最终打包程序的本次 UI 修正 | 5 组通过：英文、字体、七主题、图标、OCR 语言和独立缓存 | `test-results/packaged-refinements-result.json` |
| 原生菜单和对话框本地化 | 4 组通过 | `test-results/localization-native-result.json` |
| 打包资源与当前源码一致性 | 全部运行源码/资产逐文件比对 | `dist/release-verification.json` |

真实界面验证包括 PDF.js 渲染、文件列表、原文/扫描页选字、高亮、评论、旋转页和跨行搜索、20%–600% 范围内的缩放控制、原文跳转时保持横向位置、5 秒删除撤销、最近删除恢复、九语言目录中的语言切换、字号与分栏保存、关闭窗口时提交待保存评论、重新打开后的 OCR 缓存搜索，以及原 PDF 校验值未改变。OCR 使用合成扫描图和 Windows.Media.Ocr 实际识别，不是模拟结果。

AI 界面测试使用真实 Electron 窗口，仅替换测试进程内的聊天 IPC 响应。验证模型/推理强度目录更新、完整参考页发送、非法范围和无文字页阻止发送、连续追问、取消/失败状态、Markdown/KaTeX、HTML 清理、返回文档后旧 AI 任务完成不会覆盖新评论，以及慢速旧文件不会覆盖最后选择状态。生产代码没有模拟回复入口。

新增界面验证还覆盖英语界面的颜色/参考范围弹层、紧凑模型选择器、无衬线引用和代码文字、主题同步更新各个区域及气泡、白色/中灰自定义气泡的正文与状态文字对比度、英文 OCR 语言名称、英语与简体中文实际识别及切换后保留独立缓存。

资料库保存还通过真实 Windows 独占文件锁测试：同步软件短暂占用目标文件时有限重试原子替换，不先删除原文件。持续失败仍报错并保留原文件。

Mac 已补充设置兼容、OCR profile 缓存与语言切换、翻译、数学消息字体等原生测试源码，并修正 OCR 测试脚本的 PDFSearch 依赖。静态审查和 `git diff --check` 通过；这些 Swift 原生测试仍需在 Mac 上执行。

## 明确未验证

- 没有登录用户的真实 ChatGPT 账号，也没有真实模型调用或费用；首次运行需用户在应用内完成浏览器授权。
- 已生成 NSIS 安装程序，但没有对用户系统执行安装/卸载；验证运行的是该安装包对应的 `dist/win-unpacked/Margin.exe`。
- 没有验证 Windows 10、Windows ARM64、企业禁用 PowerShell/OCR 的环境或所有语言模型的识别质量。本机识别模型为英语和简体中文。

新版深蓝、黑色及 OCR 菜单截图：`test-results/packaged-refinements-navy.png`、`packaged-refinements-black-settings.png`、`packaged-refinements-ocr-menu.png`。

结果截图：`test-results/packaged-ocr.png`、`packaged-settings.png`、`packaged-chat-ui.png`。聊天截图包含清晰标记的模拟响应，不代表真实账号调用结果。

SHA-256 校验见 `dist/SHA256SUMS.txt`。重复构建后可以运行 `node scripts/verify-release.mjs` 重新生成校验清单；先完成对应成品测试，再将该清单作为验证记录。

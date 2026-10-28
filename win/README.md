# Margin for Windows

基于 `../mac/current` 的 Margin 开发的 Windows 桌面版，当前版本为 0.5.2。三栏布局、紧凑模型选择器、标注颜色图标、设置和九种语言沿用 Mac 设计；系统窗口按钮与文件选择器使用 Windows 控件。Mac 当前发布版本为 0.5.3，使用说明见 [Mac 版](../mac/current/README.md)。

[下载 Windows 0.5.2 安装包](https://github.com/Rosie1898/Margin/releases/download/v0.5.3/Margin-0.5.2-Windows-x64-Setup.exe) · [本次发布说明](../RELEASE_NOTES.md)

## 打开软件

本机日常安装位置记录在 `.local-install-path`，当前为 `C:\Program Files\Margin`。之后 `pnpm build` 或 `pnpm dist` 成功后会自动安装并替换这个位置的旧版，原有快捷方式继续可用。安装前正常关闭正在运行的 Margin，等待保存完成；安装后核对文件哈希，并在原先运行时重新打开。笔记、讨论、设置和登录凭据继续保存在原资料目录。全用户安装需要 Windows UAC 管理员授权。

双击 `Start.cmd`，或打开 `dist/win-unpacked/Margin.exe`。免安装版必须保留整个 `win-unpacked` 文件夹，不能只复制其中的 EXE。`dist/Margin-0.5.2-Windows-x64-Setup.exe` 是安装程序，支持选择安装位置；安装到当前用户目录不需要管理员权限，安装到 Program Files 等系统目录需要管理员授权。

运行环境：Windows 10/11 x64；当前实测环境为 Windows 11 x64。程序包含 Electron/Node 运行时，不需要另装 Node、Python、Tesseract 或其他 OCR 软件。当前构建没有购买的代码签名证书。

## 已移植功能

- 本地 PDF 文件夹与子目录浏览、文件名筛选、刷新、上次文件与页码恢复；PDF 内容哈希识别改名/复制的文档。
- 连续 PDF 阅读、20%–600% 缩放、适合窗口、页码跳转、文内搜索；选择文字后高亮、评论、问 AI，点击笔记回到原文，放大后保留横向位置。
- ChatGPT 浏览器授权入口、账号模型与推理强度、连续对话、取消回复、五种参考范围；离线 Markdown/KaTeX 公式显示。
- 扫描页自动本地 OCR、识别当前页/整份 PDF、取消、缓存；识别结果参与选字、标注、搜索和 AI 参考范围。
- 删除后 5 秒撤销、最近删除长期保留与恢复；三栏宽度、背景/颜色/不透明度/字号保存；九种界面语言。英语界面包含菜单、提示与错误翻译。
- 界面、笔记、聊天统一采用 Segoe UI／微软雅黑无衬线字体；Mac 使用系统无衬线。原始 PDF 和数学公式保留所需字体。
- 绿色、蓝色、低饱和紫色和粉色、灰色、深蓝和黑色主题，覆盖面板、图标及聊天气泡。更换主题自动搭配两种气泡颜色，之后仍可分别自定义。
- Lucas 入门示例仅在用户确认后从原来源下载并核对 SHA-256；不随程序分发论文。

## 本地 OCR

使用 Windows 自带的 **Windows.Media.Ocr**，通过隐藏的 Windows PowerShell 5.1 进程调用系统 WinRT 接口。OCR 不联网、不调用 ChatGPT、不消耗模型额度、不改写原 PDF。点击阅读区顶部 **OCR 图标**，可选择识别当前页、整份 PDF，以及识别语言。语言列表来自本机已安装模型，自动选项使用 Windows 用户语言；界面语言和 OCR 语言可以分别选择。

本机实测提供 `en-US` 和 `zh-Hans-CN`。其他电脑若没有所需模型，请在 **Windows 设置 → 时间和语言 → 语言和区域** 安装相应语言的 OCR 功能。受组织策略限制而无法运行 PowerShell 时，程序会显示错误；不会自动更改系统策略。

已有原生文字层的页面会跳过。切换 OCR 语言时，旧识别结果退出当前文字层，优先恢复该语言的缓存，并重新识别当前扫描页；原生文字不受影响。OCR 适合印刷体；模糊扫描、数学公式、复杂多栏和竖排可能识别错误。缓存按原 PDF 的 SHA-256、页码、语言、版本和识别图像摘要保存，重新打开后可用于搜索。

## 个性化指令

在 **设置 → 个性化** 输入你希望 AI 遵循的回答方式。内容自动保存，并随每次提问、追问发送；修改后从下一次发送生效，现有讨论也会使用最新内容。清空即可停用。此设置独立于 ChatGPT 账户的个性化设置。

每次最多发送 16,000 个 UTF-16 字符。超过限制会保留完整草稿并提示缩短，不会截断后发送。重启后设置仍保留。

## 账号与数据

主动发送 AI 问题时，文件名、选中文字、指定参考页面、本条对话历史和当前个性化指令会发送给 OpenAI。参考范围最多 200 页、合计 100,000 个 UTF-16 字符；没有可用文字的页面需先 OCR。后台不会自动发送文档。

复用了 Mac 版的账号与聊天后端。Windows 自动化验证使用模拟账号响应，没有代用户登录或发出真实模型请求；实际账号授权、可用模型与额度需要在首次登录时确认。

默认资料目录是 `%APPDATA%\Margin`，可以在设置中打开。`library.json` 保存笔记与外观，`conversations/` 保存完整讨论，`OCR/` 保存识别缓存。登录续期凭据通过 Electron safeStorage 使用 Windows DPAPI 加密，访问令牌仅驻留内存；退出登录清除保存凭据。DPAPI 绑定当前 Windows 用户，不能直接复制凭据到别的账号或电脑使用，也不隔离同一用户运行的其他程序。

退出应用后可备份整个资料目录，并单独保存原始 PDF。Windows 使用独立数据格式，目前不自动导入 Mac 的 `LeafReader` 资料库，也不跨设备同步。未发送的 AI 输入不跨会话保存。窗口正常关闭会先完成尚未提交的评论和设置保存。

## 快捷键

| 操作 | Windows 快捷键 |
| --- | --- |
| 打开单份 PDF / 选择文件夹 | Ctrl+O / Ctrl+Shift+O |
| 高亮 / 评论 / 问 AI | Ctrl+Shift+H / Ctrl+Shift+M / Ctrl+K |
| 文内搜索 / 下一处 / 上一处 | Ctrl+F / Ctrl+G / Ctrl+Shift+G |
| 设置 | Ctrl+, |
| 发送 AI 问题 | Ctrl+Enter |

## 从源码构建

需要 Windows x64、Node.js 22.12 或更新版本，以及 pnpm 11.25。推荐使用 pnpm 的锁文件安装；构建时需要网络下载运行时和打包工具，日常阅读无需联网。

```powershell
cd D:\Dropbox\Margin\win
pnpm install --frozen-lockfile --node-linker=hoisted
pnpm start
pnpm test
pnpm build
pnpm dist
```

`build` 和 `dist` 都生成安装程序并自动升级本机安装。仅生成发布包使用 `pnpm package`；安装未完成时使用 `pnpm install:local` 重试，无需重新构建。构建缓存保存在项目 `.cache/`，成功构建与安装记录分别为 `dist/local-build.json` 和 `test-results/local-install-result.json`。

也可使用 `npm install` 和 `npm run`，但 npm 不读取本项目的 pnpm 锁文件。Electron 安装脚本下载官方运行时并验证发布校验值；`prepare:assets` 将 Markdown、公式脚本和字体复制到本地资源。不要单独移动 `src` 目录。

测试开发数据可通过环境变量 `LEAF_DATA_DIR` 指定独立绝对路径。`scripts/run-tests.mjs` 将临时文件放在工作区，避免 Windows 沙箱临时目录的重命名限制。

```powershell
# 创建自有文字/扫描 PDF 测试资料，需要 Pillow 和 ReportLab，仅开发测试使用
python scripts/make-fixtures.py
node scripts/test-ui.mjs
node scripts/test-native-electron.mjs
node scripts/test-chat-ui.mjs
node scripts/test-refinements.mjs
node scripts/test-localization-electron.mjs
# 打包后重复真实桌面测试
$env:MARGIN_PACKAGED='1'
node scripts/test-ui.mjs
```

测试结果与窗口截图保存在 `test-results/`。原生 Electron 窗口和 DPAPI 测试需要正常的 Windows 桌面会话；受限进程沙箱可能无法启动 Electron。

## 保留的限制

和 Mac 版一样，暂不支持截图/图片提问、标注写回或导出、其他阅读器标注导入、跨设备同步及加密 PDF。当前发行包仅构建 x64，未验证 Windows ARM64。系统字体、文字排版和原生窗口控件会与 macOS 存在细微差异。

组件与来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，聊天后端出处见 [backend/SOURCE.json](backend/SOURCE.json)。

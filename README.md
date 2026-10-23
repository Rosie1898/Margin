# Margin

一个面向 macOS 的本地 PDF 阅读器，把高亮、评论和 AI 讨论留在原文旁边。

*A local PDF reader for macOS, with on-device OCR, highlights, notes, and AI conversations anchored to the passage you are reading.*

**v0.4.0 · macOS 14+ · Apple Silicon**

[下载 Margin 0.4.0](https://github.com/Rosie1898/Margin/releases/download/v0.4.0/Margin-0.4.0-macOS-arm64.zip) · [发布说明](https://github.com/Rosie1898/Margin/releases/tag/v0.4.0)

## 功能

- **保留文件夹结构**：按本地子文件夹浏览和搜索 PDF，记住上次打开的文件与阅读页码。
- **在原文旁做笔记**：拖选文字后，选区附近出现高亮、评论和问 AI 工具条；点击右侧笔记可定位原文。支持连续追问和长讨论折叠。
- **本地 OCR**：扫描页自动使用 Apple Vision 识别，也可处理整份 PDF。识别结果保存在本机，不消耗 ChatGPT 用量，不改写原 PDF。
- **ChatGPT 账号连接**：通过浏览器登录授权，选择账号返回的模型与推理强度；macOS 钥匙串保存续期凭据，下次启动自动尝试恢复登录。
- **可恢复的删除**：删除后有 5 秒撤销提示，也可在设置中的“最近删除”恢复；本版没有恢复截止日，不会自动永久清除。
- **可调整的三栏布局**：首次打开按 **1:3:1** 分配宽度；拖动调整后自动保存。
- **清淡的自定义外观**：调整高亮、气泡、主题颜色、背景图片、区域不透明度和界面字号。
- **九种界面语言**：简体中文、繁体中文、英语、日语、韩语、法语、德语、西班牙语、葡萄牙语；默认跟随系统。

## 安装与使用

下载上方 ZIP，解压后将 `Margin.app` 放入“应用程序”并打开。成品包含 Node.js 运行时，无需另行安装。**当前构建使用 ad-hoc 临时签名，未进行 Developer ID 分发签名或 Apple 公证**，首次打开可能需要在 macOS“隐私与安全性”设置中允许。

1. 点击“选择本地文件夹”，选择 PDF 目录。点击文件夹展开，点击 PDF 打开；新增或移动文件后可刷新列表。
2. 拖选正文，使用选区附近的“高亮”“评论”或“问 AI”。扫描页先等待本地 OCR 完成，再使用相同操作；标题栏文字识别菜单可处理整份 PDF 或取消任务。
3. 使用 AI 时，点击右侧“登录”，在 OpenAI 页面完成登录授权，再选择模型、推理强度并提问。在同一条讨论中继续追问即可保留上下文。可用选项取决于账号返回的目录。
4. 点击笔记卡片或引用内容返回原文。左下角齿轮进入设置；误删内容可在“最近删除”恢复。

阅读区支持 **20%–600%** 缩放，点击“适合窗口”恢复自动适应。三栏分隔线可以直接拖动。

| 操作 | 快捷键 |
| --- | --- |
| 选择文件夹 | `⌘⇧O` |
| 高亮选中文字 | `⌘⇧H` |
| 评论选中文字 | `⌘⇧M` |
| 向 AI 提问 | `⌘K` |
| 设置 | `⌘,` |

### 入门示例

示例采用 Robert E. Lucas, Jr. 的 *On the Mechanics of Economic Development*（1988）。**公开源码和下载应用不包含论文 PDF**；首次点击“打开入门示例”时，会询问是否从 [Stanford 托管地址](https://web.stanford.edu/~klenow/Lucas_Mechanics.pdf)下载原文件，之后可从本机缓存离线打开。文件来源与校验信息见 [Lucas-SOURCE.json](assets/Lucas-SOURCE.json)。论文权利仍归原权利人。

示例会定位到经典段落的预置高亮。打开示例会保留当前文件夹，退出后返回先前的文档与页码；删除预置高亮后不会自动重新生成。普通阅读和本地 OCR 均不依赖示例下载。

## 数据与账号

普通阅读、高亮、评论和 OCR 在本机完成，原始 PDF 不会被改写。**OCR 不发送页面到服务器，也不消耗 ChatGPT 用量**。主动发送 AI 问题时，会将文件名、所选文字、有限的当前页文字及该条讨论的历史发送给 OpenAI，并正常使用连接账号的用量；背景图片不随问题发送。

登录续期凭据由 macOS 钥匙串保存，访问令牌只保存在内存中。退出登录会清除保存的凭据；授权撤销或续期失效后需要重新登录。应用不读取其他应用的登录状态。

阅读记录、设置、标注、OCR 缓存和完整讨论保存在：

```text
~/Library/Application Support/LeafReader/
```

`LeafReader` 是沿用的内部数据目录名，可从“设置 → 通用”在 Finder 中打开。备份前请退出应用，再复制整个目录，并单独保留原始 PDF。内容完全相同的 PDF 通过内容哈希识别，改名或复制后可继续使用同一组标注；修改文件内容后会视为另一份文档。尚未发送的输入草稿不会持久保存。

## 当前限制

- OCR 适合印刷体；模糊扫描、多栏、手写、竖排和数学公式可能识别不准。已有文字层的页会跳过，不会修复质量不佳的旧文字层。详见 [本地 OCR](OCR.md)。
- 阅读器界面暂不支持截图或图片提问。
- AI 上下文限于所选片段、当前页的部分文字及本条讨论历史，没有整篇检索或完整的 LaTeX 公式排版器。
- 暂不支持标注导出、写回原 PDF、导入其他阅读器的标注、跨设备同步或密码锁定的 PDF。
- Intel Mac 尚未适配验证。

## 从源码构建

原生界面使用 **SwiftUI、AppKit、PDFKit、Vision 和 CoreText**；账号与讨论服务使用 **Node.js 内置模块**，只监听本机 `127.0.0.1` 的临时端口。

需要 Apple Silicon Mac、提供 `swiftc` 和 macOS 14+ SDK 的 Xcode Command Line Tools，以及 arm64 版 Node.js 22+。

```sh
git clone https://github.com/Rosie1898/Margin.git
cd Margin
bash scripts/build.sh
open Margin.app
```

脚本生成 `Margin.app` 并进行 ad-hoc 临时签名。默认使用 `PATH` 中的 Node；也可用 `NODE_BINARY` 指定 Node 可执行文件的绝对路径。若使用的 Node 版本与仓库记录不同，请通过 `NODE_LICENSE_FILE` 提供对应版本的完整许可文件，参见 [第三方声明](THIRD_PARTY_NOTICES.md)。

运行检查：

```sh
node --test Backend/*.test.mjs
bash scripts/test-native.sh
bash scripts/test-ocr.sh
```

后端检查使用模拟响应，不调用真实模型。原生检查覆盖本地数据、PDF 画布、服务生命周期、钥匙串、多语言、分栏布局、目录树和示例导航。OCR 检查使用合成扫描页，覆盖真实本地识别、文字选择、坐标、缓存、标注和取消；不会启动账号服务。受限或无窗口的执行环境可能无法写入钥匙串或创建 Vision 像素缓冲区，这些错误不代表检查通过，需在正常 macOS 应用环境中验证。OCR 检查可用 `--build-only` 只编译。

开发时可设置 `LEAF_DATA_DIR` 为独立的绝对路径，避免使用日常阅读记录。

[后端接口](Backend/README.md) · [版本变化](RELEASE_NOTES.md) · [字号示例与文学出处](FONT_SAMPLES.md) · [第三方声明](THIRD_PARTY_NOTICES.md)

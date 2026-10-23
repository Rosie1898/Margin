# Margin 0.4.0

## 中文

Margin 的首个公开发布版本：一个把 PDF 高亮、评论和 AI 讨论留在原文旁边的 Mac 本地阅读器。**要求 macOS 14 或更新版本、Apple Silicon 芯片，构建号 12。**

### 安装

1. 下载 [Margin-0.4.0-macOS-arm64.zip](https://github.com/Rosie1898/Margin/releases/download/v0.4.0/Margin-0.4.0-macOS-arm64.zip)。
2. 解压，将 `Margin.app` 拖入“应用程序”并打开。成品包含 Node.js **v24.19.0**，无需另行安装运行时。
3. 本构建使用 **ad-hoc 临时签名**，未进行 Developer ID 分发签名或 Apple 公证。首次打开可能需要确认来源后，在 macOS“隐私与安全性”设置中允许打开。

### 本地 OCR

- 无文字层的扫描页自动使用 Apple Vision 识别；完成后可以选择文字、高亮、评论和向 AI 提问。
- 支持当前页或整份 PDF 识别、进度显示、取消和本地缓存；已有文字层的页面会跳过。
- OCR 完全在本机完成，不发送页面到服务器，不调用 ChatGPT，也不消耗 ChatGPT 用量。原始 PDF 保持不变，识别结果单独缓存。主动向 AI 提问时仍正常使用连接账号的用量。
- 模糊扫描、复杂版面、手写、竖排和数学公式可能识别不准；不会修复已有但质量不佳的文字层。详见 [本地 OCR](https://github.com/Rosie1898/Margin/blob/v0.4.0/OCR.md)。

### 阅读、笔记与讨论

- 按原有子文件夹结构浏览 PDF，保存阅读位置。首次打开的三栏比例为 **1:3:1**，手动调整后自动保存并恢复。
- 选区附近的浮动工具条提供高亮、普通评论和问 AI；修复在选项间移动时的光标闪烁。
- 右侧讨论与原文位置关联，支持连续追问、长回复折叠和点击笔记定位原文。
- ChatGPT 登录通过浏览器完成。模型和推理强度来自账号可用目录；续期凭据由 macOS 钥匙串保存，下次启动自动尝试恢复登录。
- 高亮、评论和讨论支持删除、5 秒撤销提示及“最近删除”恢复；本版不自动永久清除。
- 可自定义主题、高亮与气泡颜色、背景图片、区域不透明度和字号。支持九种界面语言，默认跟随系统。
- 使用白底绿色 **M** 图标。日语字号示例采用三島由紀夫《金閣寺》的短句，各语言示例及出处见 [字号示例](https://github.com/Rosie1898/Margin/blob/v0.4.0/FONT_SAMPLES.md)。

### 入门示例与数据

- Lucas 的 *On the Mechanics of Economic Development* 示例与正常阅读目录分开；退出示例返回先前的文件与页码。
- 公开源码与应用不捆绑论文。首次打开示例时，经用户确认从 Stanford 托管地址下载原文件，并缓存供离线使用；普通阅读与 OCR 不依赖这次下载。
- 阅读记录、标注、OCR 缓存和讨论保存在本机。发送 AI 问题时，会将文件名、选中文字、有限的当前页文字及该条讨论历史发送给 OpenAI。背景图片不随问题发送。
- 第三方许可随应用提供，详见 [第三方声明](https://github.com/Rosie1898/Margin/blob/v0.4.0/THIRD_PARTY_NOTICES.md)。

### 当前限制

暂不支持 Intel Mac、密码锁定的 PDF、界面截图或图片提问、整篇检索、完整 LaTeX 公式排版、标注导出或写回原 PDF、导入其他阅读器的标注，以及跨设备同步。

[完整使用与构建说明](https://github.com/Rosie1898/Margin/blob/v0.4.0/README.md)

---

## English

The first public release of Margin: a local Mac PDF reader that keeps highlights, notes, and AI conversations beside the passages they refer to. **Requires macOS 14 or later and Apple Silicon. Build 12.**

### Installation

1. Download [Margin-0.4.0-macOS-arm64.zip](https://github.com/Rosie1898/Margin/releases/download/v0.4.0/Margin-0.4.0-macOS-arm64.zip).
2. Unzip it, drag `Margin.app` into Applications, and open it. Node.js **v24.19.0** is included; no separate runtime installation is required.
3. This build is **ad-hoc signed**. It does not have a Developer ID distribution signature and is not notarized by Apple. On first launch, macOS may require you to allow it in Privacy & Security settings after confirming its source.

### On-device OCR

- Scanned pages without a text layer are recognized automatically using Apple Vision. Once recognition finishes, you can select text, highlight it, add notes, and ask AI questions.
- Recognize the current page or the entire PDF, with progress, cancellation, and a local cache. Pages that already have a text layer are skipped.
- OCR runs entirely on your Mac. It does not send pages to a server, call ChatGPT, or consume ChatGPT usage. The original PDF stays unchanged; recognition results are cached separately. AI questions you choose to send use the connected account normally.
- Blurry scans, complex layouts, handwriting, vertical text, and mathematical formulas may be recognized incorrectly. Existing low-quality text layers are not repaired. See the [local OCR guide](https://github.com/Rosie1898/Margin/blob/v0.4.0/OCR.md).

### Reading, notes, and conversations

- Browse PDFs in their original subfolder structure and resume your reading position. The three panes start at a **1:3:1** ratio; manual adjustments are saved and restored.
- A floating toolbar beside selected text provides Highlight, Comment, and Ask AI. Cursor flickering when moving between its controls has been fixed.
- Conversations in the right sidebar stay linked to the source passage. Continue with follow-up questions, collapse long replies, and click a note to return to its location.
- Sign in to ChatGPT through your browser. Models and reasoning levels come from the options available to your account. Renewal credentials are stored in macOS Keychain, and the app attempts to restore sign-in when it starts again.
- Delete highlights, notes, and conversations, undo within 5 seconds, or restore them from Recently Deleted. This version does not automatically erase deleted items permanently.
- Customize theme, highlight, and conversation colors, background images, pane opacity, and font size. Nine interface languages are supported, with the system language used by default.
- A green **M** on white is used as the app icon. The Japanese font-size sample quotes Yukio Mishima’s *The Temple of the Golden Pavilion*. All language samples and their sources are listed in [font-size samples](https://github.com/Rosie1898/Margin/blob/v0.4.0/FONT_SAMPLES.md).

### Sample document and data

- The sample, Lucas’s *On the Mechanics of Economic Development*, opens separately from your normal reading folder. Leaving the sample returns you to the previous document and page.
- The public source and application do not bundle the paper. The first time you open the sample, the app asks for confirmation before downloading the original file from its Stanford-hosted source. It is then cached for offline use. Normal reading and OCR do not depend on this download.
- Reading history, annotations, OCR caches, and conversations are stored locally. When you send an AI question, the filename, selected text, limited current-page text, and that conversation’s history are sent to OpenAI. Background images are not sent with questions.
- Third-party licenses are included with the application. See [third-party notices](https://github.com/Rosie1898/Margin/blob/v0.4.0/THIRD_PARTY_NOTICES.md).

### Current limitations

This release does not support Intel Macs, password-locked PDFs, screenshot or image questions in the interface, whole-document retrieval, full LaTeX rendering, annotation export or writing annotations into the original PDF, importing annotations from other readers, or cross-device synchronization.

[Full usage and build instructions](https://github.com/Rosie1898/Margin/blob/v0.4.0/README.md)

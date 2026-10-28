# Margin 0.5.0

[中文](#中文) | [English](#english)

## 中文

本次更新让放大阅读、查找文字和 AI 讨论更顺手。**要求 macOS 14 或更新版本、Apple Silicon 芯片，构建号 13。**

### 更新内容

- **评论跳转保持横向位置**：点击评论或引用原文时，只上下移动到对应位置；放大 PDF 后不再左右跳动。
- **PDF 文内搜索**：按 `⌘F` 查找关键词，用 `⌘G` / `⌘⇧G` 跳到下一处／上一处匹配。搜索包含原有文字层和已完成本地 OCR 的页面。
- **AI 回复公式排版**：Markdown 与 KaTeX 数学公式在本机渲染，脚本、样式和字体随应用提供。打开已保存的回复也会使用新排版，可离线显示。
- **每轮选择 AI 参考范围**：可选仅选中文字、划线所在页、前后各一页、指定页码或整份文档。范围选择随讨论保存，连续追问时可以调整；选中文字和本条讨论历史继续保留，之前发送的参考资料仍在历史中。

每轮参考最多 **200 页、100,000 个字符（UTF-16 计数）**。指定页码可输入 `1-3, 5`，以阅读区底部的 PDF 页序为准。页面文字超过上限时会提示缩小范围，不会截断；缺少文字的页面可先运行本地 OCR。

### 安装

1. 下载 [Margin-0.5.0-macOS-arm64.zip](https://github.com/Rosie1898/Margin/releases/download/v0.5.0/Margin-0.5.0-macOS-arm64.zip)。
2. 解压，将 `Margin.app` 拖入“应用程序”并打开。应用包含 Node.js 运行时，无需另行安装。
3. 本构建使用 **ad-hoc 签名，未进行 Apple 公证**。首次打开如被 macOS 拦截，进入“系统设置 → 隐私与安全性 → 仍要打开”，再按提示确认。见 [Apple 说明](https://support.apple.com/en-us/102445)。

### 示例与数据

Lucas 的 *On the Mechanics of Economic Development* 示例在首次点击时，经确认从 Stanford 下载并缓存在本机，安装包不包含论文。退出示例会返回先前的文档与页码。

阅读、标注、搜索、OCR 和公式排版在本机完成，原始 PDF 保持不变；OCR 不消耗 ChatGPT 用量。主动发送 AI 问题时，会将文件名、选中文字、本轮参考页面和该条讨论历史发送给 OpenAI，并使用连接账号的用量。登录续期凭据保存在 macOS 钥匙串，阅读记录和讨论继续保留。

[完整使用与构建说明](https://github.com/Rosie1898/Margin/blob/v0.5.0/README.md) · [第三方声明](https://github.com/Rosie1898/Margin/blob/v0.5.0/THIRD_PARTY_NOTICES.md)

---

## English

This update improves zoomed reading, text search, and AI discussions. **Requires macOS 14 or later and Apple Silicon. Build 13.**

### What’s new

- **Comment navigation preserves horizontal position**: clicking a comment or quoted passage scrolls vertically to its location, keeping the PDF’s horizontal position when zoomed in.
- **PDF text search**: press `⌘F` to find text, then use `⌘G` / `⌘⇧G` to move to the next / previous match. Search includes existing text layers and pages with completed local OCR.
- **Math rendering in AI replies**: Markdown and KaTeX formulas render locally using bundled scripts, styles, and fonts. Previously saved replies also use the new rendering and can be displayed offline.
- **Choose AI context for each turn**: use only the selection, its page, the current and adjacent pages, custom pages, or the entire document. The choice is saved with the conversation and can change for follow-ups. The selected text and conversation history are retained, including previously supplied reference material.

Each turn accepts up to **200 context pages and 100,000 characters (counted in UTF-16)**. Enter custom pages as `1-3, 5`, using the PDF page numbers shown at the bottom of the reader. Text over the limit prompts a smaller range instead of being truncated. Run local OCR first for pages without text.

### Installation

1. Download [Margin-0.5.0-macOS-arm64.zip](https://github.com/Rosie1898/Margin/releases/download/v0.5.0/Margin-0.5.0-macOS-arm64.zip).
2. Unzip it, drag `Margin.app` into Applications, and open it. Node.js is included; no separate runtime installation is required.
3. This build is **ad-hoc signed and has not been notarized by Apple**. If macOS blocks the first launch, go to **System Settings → Privacy & Security → Open Anyway** and confirm when prompted. See [Apple’s instructions](https://support.apple.com/en-us/102445).

### Sample and data

The sample, Lucas’s *On the Mechanics of Economic Development*, downloads from Stanford after confirmation the first time you open it and is then cached locally. The installer does not include the paper. Leaving the sample returns you to your previous document and page.

Reading, annotations, search, OCR, and math rendering run locally, leaving the original PDF unchanged. OCR does not consume ChatGPT usage. When you send an AI question, the filename, selected text, current context pages, and conversation history are sent to OpenAI and use the connected account’s allowance. Renewal credentials are stored in macOS Keychain, and reading records and conversations are retained.

[Full usage and build instructions](https://github.com/Rosie1898/Margin/blob/v0.5.0/README.md) · [Third-party notices](https://github.com/Rosie1898/Margin/blob/v0.5.0/THIRD_PARTY_NOTICES.md)

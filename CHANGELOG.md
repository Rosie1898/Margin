# Margin Changelog

## 0.5.0 — 未发布 / Unreleased

### 中文

- 点击评论回到原文时保留横向位置，放大阅读时不再左右跳动。
- 新增 PDF 文内搜索：`⌘F` 打开，`⌘G` / `⌘⇧G` 切换下一处／上一处匹配；支持已有文字层和已完成 OCR 的页面。
- AI 回复使用随应用提供的 Markdown 与 KaTeX 组件排版公式，可离线显示。
- 每轮提问可选择仅选中文字、划线所在页、前后各一页、指定页码或整份文档；选择随讨论保存，追问可调整，历史继续保留。
- 每轮参考最多 200 页、100,000 个 UTF-16 字符；缺少文字时提示运行本地 OCR，文字过多时提示缩小范围。

### English

- Returning to a passage from a comment preserves the horizontal reading position when zoomed in.
- Added PDF text search: `⌘F` opens search; `⌘G` / `⌘⇧G` moves to the next / previous match. Search covers existing text layers and pages with completed OCR.
- AI replies render Markdown and KaTeX formulas locally using bundled components, including while offline.
- Each turn can use the selection, its page, the current and adjacent pages, custom pages, or the entire document. The choice is saved with the conversation and can change for follow-ups while preserving history.
- Each turn accepts up to 200 context pages and 100,000 UTF-16 characters. Pages without text prompt local OCR; longer text prompts a smaller range.

## 0.4.0

首个公开版本，包含本地 OCR、文件夹浏览、高亮、评论和 ChatGPT 讨论。

First public release, with on-device OCR, folder browsing, highlights, comments, and ChatGPT conversations.

[中英双语发布说明 / Bilingual release notes](RELEASE_NOTES.md) · [GitHub Release](https://github.com/Rosie1898/Margin/releases/tag/v0.4.0)

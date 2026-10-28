# Third-party components

Margin Windows ports the user's Margin macOS 0.5.0 source in `../mac/current` (recorded upstream commit `0e86a2cc5ca5ca3c49072aafad25bc27afc458d5`). The 0.5.1 refinements also update the Mac source for OCR language selection, themes and typography. The portable Node account/conversation implementation, UI language catalog, original icon and sample provenance are reused.

Runtime dependencies are pinned in `package.json` and `pnpm-lock.yaml`:

| Component | Version | License / source |
| --- | --- | --- |
| Electron | 45.0.0 | MIT; Chromium and Node notices included in the distribution's LICENSE and LICENSES.chromium.html; https://github.com/electron/electron |
| PDF.js | 6.4.299 | Apache-2.0; https://github.com/mozilla/pdf.js |
| KaTeX | 0.19.1 | MIT; includes locally bundled fonts; https://github.com/KaTeX/KaTeX |
| Marked | 18.1.1 | MIT; https://github.com/markedjs/marked |
| DOMPurify | 3.4.17 | Apache-2.0 or MPL-2.0; https://github.com/cure53/DOMPurify |

Development tools include electron-builder (MIT), Playwright (Apache-2.0), and Python Pillow/ReportLab for synthetic test fixtures and conversion of the original application icon. These Python libraries are not required by the packaged reader.

Windows.Media.Ocr is a Windows OS component and uses installed Windows recognition languages. No cloud OCR service or downloaded recognition model is bundled. Microsoft documentation: https://learn.microsoft.com/en-us/uwp/api/windows.media.ocr.ocrengine

The Lucas paper is not redistributed. Its Stanford source and expected checksum are recorded in `assets/Lucas-SOURCE.json`; the application asks the reader before downloading and verifies the original bytes. All paper rights remain with their owners.

Font-size preview quotations and attribution are ported from `mac/current/Sources/FontSamples.swift` and `mac/current/FONT_SAMPLES.md`.

# Third-party notices

## Node.js

The macOS v0.4.0 release bundles the official Node.js v24.19.0 darwin-arm64 runtime. Its complete license, including bundled dependency notices, is in [third_party/node/LICENSE](third_party/node/LICENSE) and in `Margin.app/Contents/Resources/ThirdParty/Node-LICENSE.txt`. Archive source and checksum are recorded in [SOURCE.json](third_party/node/SOURCE.json).

When redistributing a build with a different Node.js version, include that distribution’s complete license via `NODE_LICENSE_FILE`.

## System frameworks

The reader uses Apple system frameworks, including PDFKit, Vision, and CoreText, and Node.js built-in modules. No external JavaScript packages are required. The OCR implementation runs on the Mac using Apple Vision.

## Optional sample paper

The public source repository and release application do not contain Robert E. Lucas, Jr.’s *On the Mechanics of Economic Development* (1988). At the user’s request and after confirmation, the application downloads the unchanged PDF from its [Stanford-hosted source](https://web.stanford.edu/~klenow/Lucas_Mechanics.pdf) and caches it locally. Source information and the expected checksum are recorded in [assets/Lucas-SOURCE.json](assets/Lucas-SOURCE.json).

The paper remains the property of its respective rights holders. Providing a source link or a local download feature does not grant a redistribution license.

## Font-size samples

Short literary excerpts are used to preview font size in the selected interface language. Authors, works, and source links are listed in [FONT_SAMPLES.md](FONT_SAMPLES.md). Rights in quoted works remain with their respective rights holders.

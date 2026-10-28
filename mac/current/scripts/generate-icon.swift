import AppKit

@main
struct GenerateIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "GenerateIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass the output assets directory."])
        }
        let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = assets.deletingLastPathComponent().appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        var iconChunks = Data()
        for (name, pixels, type) in [("icon_16x16",16,"icp4"), ("icon_16x16@2x",32,"ic11"), ("icon_32x32",32,"icp5"), ("icon_32x32@2x",64,"ic12"), ("icon_128x128",128,"ic07"), ("icon_128x128@2x",256,"ic13"), ("icon_256x256",256,"ic08"), ("icon_256x256@2x",512,"ic14"), ("icon_512x512",512,"ic09"), ("icon_512x512@2x",1024,"ic10")] {
            let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
            let graphics = NSGraphicsContext(bitmapImageRep: representation)!
            let context = graphics.cgContext
            context.translateBy(x: 0, y: CGFloat(pixels))
            context.scaleBy(x: 1, y: -1)
            BrandArtwork.draw(in: context, size: CGSize(width: pixels, height: pixels), includesBackground: true)
            let png = representation.representation(using: .png, properties: [:])!
            try png.write(to: iconset.appendingPathComponent(name + ".png"))
            if pixels == 1024 { try png.write(to: assets.appendingPathComponent("AppIcon.png")) }
            iconChunks.append(Data(type.utf8))
            appendBigEndianLength(png.count + 8, to: &iconChunks)
            iconChunks.append(png)
        }
        var icns = Data("icns".utf8)
        appendBigEndianLength(iconChunks.count + 8, to: &icns)
        icns.append(iconChunks)
        try icns.write(to: assets.appendingPathComponent("AppIcon.icns"))
        guard let image = NSImage(contentsOf: assets.appendingPathComponent("AppIcon.icns")), !image.representations.isEmpty else {
            throw NSError(domain: "GenerateIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Generated ICNS could not be decoded."])
        }
        print("Generated and decoded AppIcon.icns (\(image.representations.count) representations), AppIcon.iconset, and AppIcon.png")
    }

    private static func appendBigEndianLength(_ value: Int, to data: inout Data) {
        var length = UInt32(value).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    }
}

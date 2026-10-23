import SwiftUI
import AppKit

enum Branding {
    // Display names can change without changing the persistent application identity.
    static let displayName = "Margin"
    static let shortName = "Margin"
    static let englishName = "MARGIN"
    static let iconResource = "MarginMonogram"
}

/// Keep the title's full intrinsic width, with space inside the system capsule.
struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 7) {
            BrandMark().frame(width: 20, height: 20)
            Text(Branding.displayName)
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// The same custom vector mark is used in the reader and the generated app icon.
struct BrandMark: View {
    var body: some View {
        Canvas { context, size in
            context.withCGContext { canvas in
                BrandArtwork.draw(in: canvas, size: size, includesBackground: true)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

enum BrandArtwork {
    /// White tile and a geometric green M, shared by the title bar and Dock icon.
    static func draw(in context: CGContext, size: CGSize, includesBackground: Bool) {
        context.saveGState()
        defer { context.restoreGState() }
        context.scaleBy(x:size.width/1024, y:size.height/1024)
        if includesBackground {
            let tile = CGPath(roundedRect:CGRect(x:48,y:48,width:928,height:928), cornerWidth:210, cornerHeight:210, transform:nil)
            context.saveGState()
            context.setShadow(offset:CGSize(width:0,height:7),blur:19,color:CGColor(gray:0,alpha:0.12))
            context.addPath(tile)
            context.setFillColor(CGColor(gray:1,alpha:1))
            context.fillPath()
            context.restoreGState()
            context.addPath(tile)
            context.setStrokeColor(CGColor(gray:0.5,alpha:0.12))
            context.setLineWidth(2)
            context.strokePath()
        }
        let letter = CGMutablePath()
        let points: [CGPoint] = [
            .init(x:266,y:738), .init(x:266,y:286), .init(x:366,y:286),
            .init(x:512,y:550), .init(x:658,y:286), .init(x:758,y:286),
            .init(x:758,y:738), .init(x:658,y:738), .init(x:658,y:478),
            .init(x:549,y:670), .init(x:475,y:670), .init(x:366,y:478),
            .init(x:366,y:738)
        ]
        letter.addLines(between:points)
        letter.closeSubpath()
        context.addPath(letter)
        context.setFillColor(CGColor(red:47/255,green:118/255,blue:94/255,alpha:1))
        context.fillPath()
    }
}

// Draws arrdeck/frontend/public/favicon.svg's layers at 1024px, laid out like pwa-512.png
// (full bleed, no border: iOS applies its own corner mask). Opaque, as iOS wants.
// Usage: swift Scripts/render-icon.swift App/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let scale: CGFloat = 12.8          // 6.4 in pwa-512, doubled
let ox: CGFloat = 102.4, oy: CGFloat = 108.8
func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// SVG's y axis points down
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)
ctx.setFillColor(rgb(0x181d29)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
func poly(_ pts: [(CGFloat, CGFloat)], _ color: UInt32) {
    ctx.beginPath()
    ctx.addLines(between: pts.map { CGPoint(x: ox + $0.0 * scale, y: oy + $0.1 * scale) })
    ctx.closePath(); ctx.setFillColor(rgb(color)); ctx.fillPath()
}
poly([(12, 40), (32, 51), (52, 40), (52, 44), (32, 55), (12, 44)], 0x2a3145)
poly([(12, 31), (32, 42), (52, 31), (52, 35), (32, 46), (12, 35)], 0x8b94ab)
poly([(32, 9), (52, 20), (32, 31), (12, 20)], 0x5b8cff)
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))

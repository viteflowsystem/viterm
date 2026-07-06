// Deterministically renders the viterm AppIcon with Core Graphics.
// Final version of logo candidate 01 "Prompt" (docs/brand/logo-candidates.html).
//
// Usage: swift scripts/make-appicon.swift        → Resources/AppIcon.icns
//        swift scripts/make-appicon.swift dev    → Resources/AppIcon-Dev.icns (with DEV badge)
// Output: all sizes, via iconutil.
//
// Design (on a 256pt canvas):
// - Follows the macOS icon grid: 824px rounded square (corner radius 185px)
//   within 1024px, plus transparent margin
// - Background: navy #1E2442 (viteflow system brand)
// - ❯ prompt: stroke filled with the brand gradient #FF8A47→#FFBE3D→#FF7A4C→#FF3B8E
// - Cursor block: same gradient, horizontal

import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let isDev = CommandLine.arguments.contains("dev")

let brandStops: [(CGFloat, NSColor)] = [
    (0.00, NSColor(red: 0xFF / 255, green: 0x8A / 255, blue: 0x47 / 255, alpha: 1)),
    (0.33, NSColor(red: 0xFF / 255, green: 0xBE / 255, blue: 0x3D / 255, alpha: 1)),
    (0.60, NSColor(red: 0xFF / 255, green: 0x7A / 255, blue: 0x4C / 255, alpha: 1)),
    (1.00, NSColor(red: 0xFF / 255, green: 0x3B / 255, blue: 0x8E / 255, alpha: 1)),
]
let navy = CGColor(red: 0x1E / 255, green: 0x24 / 255, blue: 0x42 / 255, alpha: 1)

func makeGradient() -> CGGradient {
    let colors = brandStops.map { $0.1.cgColor } as CFArray
    let locations = brandStops.map { $0.0 }
    return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: locations)!
}

/// Draws the icon onto a 1024px canvas.
func draw(in ctx: CGContext) {
    let canvas: CGFloat = 1024

    // Rounded square (Apple icon grid: 824 within 1024, corner radius ~185)
    let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let plate = CGPath(roundedRect: plateRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(plate)
    ctx.setFillColor(navy)
    ctx.fillPath()

    // From here on, draw in the 256pt design coordinate space (top origin),
    // mapped onto the plate area (824px) so everything stays inside the plate.
    ctx.saveGState()
    ctx.translateBy(x: plateRect.minX, y: plateRect.minY + plateRect.height)
    ctx.scaleBy(x: plateRect.width / 256, y: -plateRect.height / 256)

    // ❯ prompt (convert the stroke to a path and fill it with the gradient)
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: 74, y: 82))
    chevron.addLine(to: CGPoint(x: 136, y: 128))
    chevron.addLine(to: CGPoint(x: 74, y: 174))
    let stroked = chevron.copy(
        strokingWithWidth: 27,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 10
    )
    ctx.saveGState()
    ctx.addPath(stroked)
    ctx.clip()
    ctx.drawLinearGradient(
        makeGradient(),
        start: CGPoint(x: 60, y: 68),
        end: CGPoint(x: 150, y: 188),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Cursor block (horizontal gradient)
    let cursor = CGPath(
        roundedRect: CGRect(x: 148, y: 152, width: 52, height: 21),
        cornerWidth: 7, cornerHeight: 7, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(cursor)
    ctx.clip()
    ctx.drawLinearGradient(
        makeGradient(),
        start: CGPoint(x: 148, y: 162),
        end: CGPoint(x: 200, y: 162),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    ctx.restoreGState()

    // DEV badge: amber ribbon with "DEV" at the bottom of the plate,
    // so dev builds are recognizable even at small Dock sizes
    if isDev {
        let amber = CGColor(red: 0xFF / 255, green: 0xBE / 255, blue: 0x3D / 255, alpha: 1)
        let banner = CGPath(
            roundedRect: CGRect(x: 232, y: 140, width: 560, height: 190),
            cornerWidth: 44, cornerHeight: 44, transform: nil
        )
        ctx.addPath(banner)
        ctx.setFillColor(amber)
        ctx.fillPath()

        let text = NSAttributedString(string: "DEV", attributes: [
            .font: NSFont.systemFont(ofSize: 140, weight: .black),
            .foregroundColor: NSColor(red: 0x1E / 255, green: 0x24 / 255, blue: 0x42 / 255, alpha: 1),
            .kern: 8,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: 512 - bounds.midX, y: 235 - bounds.midY)
        CTLineDraw(line, ctx)
    }
    _ = canvas
}

func renderPNG(pixels: Int, to url: URL) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(in: ctx)
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let fm = FileManager.default
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let suffix = isDev ? "-Dev" : ""
let iconset = repoRoot.appendingPathComponent(".build/AppIcon\(suffix).iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in entries {
    renderPNG(pixels: px, to: iconset.appendingPathComponent(name))
}

let out = repoRoot.appendingPathComponent("Resources/AppIcon\(suffix).icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "OK: \(out.path)" : "iconutil failed: \(task.terminationStatus)")

// generate-appicon.swift — deterministic AppIcon generator for SuperDictate
// Next. Renders every macOS iconset size as PNGs into
// <outdir>/AppIcon.iconset; run iconutil afterwards to build Parakey.icns.
//
// Design brief (v0.5.4 rebrand): keep the microphone concept, make it modern
// and vivid — a diagonal indigo→violet→pink gradient plate, a soft top sheen,
// a white microphone with a gentle drop shadow, and translucent sound-wave
// arcs on both sides for energy. Pure CoreGraphics, no external deps.
//
// Usage (no arguments — the swift driver in some environments rewrites
// positional args, so paths are fixed/environment-driven):
//   APPICON_PREVIEW=dist/appicon-preview.png swift icon/generate-appicon.swift
//   iconutil -c icns icon/build/AppIcon.iconset -o icon/Parakey.icns

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: "icon/build")
var previewURL: URL?
if let preview = ProcessInfo.processInfo.environment["APPICON_PREVIEW"] {
    previewURL = URL(fileURLWithPath: preview)
}

let masterSize = 1024

func makeContext(_ px: Int) -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    return CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                     bytesPerRow: 0, space: space,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func drawIcon(_ ctx: CGContext, px: Int) {
    let s = CGFloat(px) / CGFloat(masterSize)
    let full = CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

    // Plate: rounded squircle (macOS-style mask ratio ≈ 0.2237).
    let radius = 229.0 * s
    let plate = CGPath(roundedRect: full, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()

    // Diagonal gradient: indigo → violet → pink.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [CGColor(srgbRed: 0.365, green: 0.345, blue: 0.965, alpha: 1),
                                       CGColor(srgbRed: 0.575, green: 0.345, blue: 0.965, alpha: 1),
                                       CGColor(srgbRed: 0.945, green: 0.290, blue: 0.600, alpha: 1)] as CFArray,
                              locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: full.height),
                           end: CGPoint(x: full.width, y: 0),
                           options: [])

    // Soft sheen across the top third.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
                                    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: 0, y: full.height * 0.97),
                           end: CGPoint(x: 0, y: full.height * 0.45),
                           options: [])

    // Sound-wave arcs, left and right (drawn behind the mic).
    for (radiusBase, alpha) in [(248.0, 0.50), (320.0, 0.28)] {
        for side in [-1.0, 1.0] {
            let a0: CGFloat = side == -1 ? 150 : 30
            let a1: CGFloat = side == -1 ? 210 : -30
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha))
            ctx.setLineWidth(26 * s)
            ctx.setLineCap(.round)
            ctx.addArc(center: p(512, 545), radius: radiusBase * s,
                       startAngle: min(a0, a1) * .pi / 180,
                       endAngle: max(a0, a1) * .pi / 180, clockwise: false)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // Microphone group with a gentle shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 56 * s,
                  color: CGColor(srgbRed: 0.10, green: 0.05, blue: 0.25, alpha: 0.35))
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    // Body capsule.
    let body = CGRect(x: (512 - 88) * s, y: 360 * s, width: 176 * s, height: 340 * s)
    ctx.setFillColor(white)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 88 * s, cornerHeight: 88 * s, transform: nil))
    ctx.fillPath()

    // Stand: stem + U arc, stroked round.
    let stand = CGMutablePath()
    stand.move(to: p(402, 368))
    stand.addLine(to: p(402, 300))
    stand.addArc(center: p(512, 300), radius: 110 * s,
                 startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    stand.addLine(to: p(622, 368))
    ctx.setStrokeColor(white)
    ctx.setLineWidth(34 * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(stand)
    ctx.strokePath()
    ctx.restoreGState() // shadow

    // Grille hint: two translucent slots inside the capsule (skip tiny sizes).
    if px >= 128 {
        ctx.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.30, blue: 0.85, alpha: 0.28))
        ctx.setLineWidth(14 * s)
        ctx.setLineCap(.round)
        for y in [470, 540] as [CGFloat] {
            ctx.move(to: p(512 - 56, y))
            ctx.addLine(to: p(512 + 56, y))
        }
        ctx.strokePath()
    }

    ctx.restoreGState() // plate clip
}

func renderPNG(px: Int) -> Data {
    let ctx = makeContext(px)
    drawIcon(ctx, px: px)
    let image = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

let iconsetDir = outDir.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

if let previewURL {
    try renderPNG(px: masterSize).write(to: previewURL)
    print("preview written: \(previewURL.path)")
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes {
    try renderPNG(px: px).write(to: iconsetDir.appendingPathComponent(name))
}
print("generated \(sizes.count) PNGs in \(iconsetDir.path)")

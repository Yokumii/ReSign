// Regenerate Resources/AppIcon.icns and Resources/AppIcon.png:
// swift scripts/generate-app-icon.swift

import AppKit
import SwiftUI

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let symbol: NSImage = MainActor.assumeIsolated {
    // Keep the title's font and symbol rendering, including the rounded signature variant.
    let renderer = ImageRenderer(content: Image(systemName: "signature")
        .font(.system(size: 27, weight: .semibold, design: .rounded))
        .foregroundStyle(Color(white: 0.9)))
    renderer.scale = 32
    guard let image = renderer.nsImage else { fatalError("无法加载 signature 符号。") }
    return image
}

func render(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("无法创建应用图标画布。")
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.interpolationQuality = .high

    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let gradient = NSGradient(starting: NSColor(calibratedWhite: 0.20, alpha: 1),
                                    ending: NSColor(calibratedWhite: 0.13, alpha: 1)) else {
        fatalError("无法创建应用图标背景。")
    }
    gradient.draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.10).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let width: CGFloat = 588
    let height = width * symbol.size.height / symbol.size.width
    symbol.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2, width: width, height: height))

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("无法编码应用图标。")
    }
    return png
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let data = try render(pixels: points * scale)
    let suffix = scale == 2 ? "@2x" : ""
    try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"), options: .atomic)
    if points == 512 && scale == 2 {
        try data.write(to: resources.appendingPathComponent("AppIcon.png"), options: .atomic)
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("生成 AppIcon.icns 失败。") }
print("已生成 Resources/AppIcon.icns 和 Resources/AppIcon.png")

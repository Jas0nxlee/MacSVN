#!/usr/bin/env swift
// 生成 MacSVN 的 AppIcon.icns：swift scripts/make-icon.swift <输出目录>
import AppKit
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetURL = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.iconset")

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size),
                               pixelsHigh: Int(size),
                               bitsPerSample: 8,
                               samplesPerPixel: 4,
                               hasAlpha: true,
                               isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0,
                               bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.225
    let body = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.055, dy: size * 0.055),
                            xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.32, green: 0.55, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.28, blue: 0.72, alpha: 1),
    ])!
    gradient.draw(in: body, angle: -90)

    // 顶部浏览栏
    let barHeight = size * 0.17
    let barRect = NSRect(x: rect.minX + size * 0.055,
                         y: rect.maxY - size * 0.055 - barHeight,
                         width: rect.width - size * 0.11,
                         height: barHeight)
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSColor(calibratedWhite: 1, alpha: 0.22).setFill()
    barRect.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 红黄绿三个圆点
    let dotSize = size * 0.045
    let dotY = barRect.midY - dotSize / 2
    for (index, color) in [NSColor(calibratedRed: 1, green: 0.42, blue: 0.38, alpha: 1),
                           NSColor(calibratedRed: 1, green: 0.78, blue: 0.3, alpha: 1),
                           NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.4, alpha: 1)].enumerated() {
        let dot = NSRect(x: barRect.minX + size * 0.045 + CGFloat(index) * dotSize * 1.9,
                         y: dotY, width: dotSize, height: dotSize)
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    // 上传箭头
    let centerX = size / 2
    let arrowBottom = size * 0.3
    let arrowTop = size * 0.66
    let arrowWidth = size * 0.115
    NSColor.white.setFill()
    let shaft = NSRect(x: centerX - arrowWidth / 2, y: arrowBottom,
                       width: arrowWidth, height: arrowTop - arrowBottom)
    NSBezierPath(roundedRect: shaft, xRadius: arrowWidth * 0.35, yRadius: arrowWidth * 0.35).fill()
    let head = NSBezierPath()
    let headWidth = size * 0.2
    head.move(to: NSPoint(x: centerX, y: arrowTop + size * 0.1))
    head.line(to: NSPoint(x: centerX - headWidth / 2, y: arrowTop - size * 0.02))
    head.line(to: NSPoint(x: centerX + headWidth / 2, y: arrowTop - size * 0.02))
    head.close()
    head.fill()

    // 底部托盘
    let tray = NSRect(x: size * 0.28, y: size * 0.22, width: size * 0.44, height: size * 0.07)
    NSBezierPath(roundedRect: tray, xRadius: tray.height / 2, yRadius: tray.height / 2).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.removeItem(at: iconsetURL)
try! FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let rep = draw(size: variant.pixels)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: iconsetURL.appendingPathComponent("\(variant.name).png"))
}

print(iconsetURL.path)

#!/usr/bin/env swift
// 生成 MiraQuota 的应用图标。图形是一圈额度弧：底环为满额，实色弧为已用，
// 缺口留在正下方，与面板上的进度条同义。不依赖任何图形资源，随构建重新画出。
//
// 用法：swift scripts/make-icon.swift <输出目录>，产出 <输出目录>/icon.icns

import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconset = URL(fileURLWithPath: out).appending(path: "MiraQuota.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// macOS 图标在 1024 的画布上留出四周边距，实际图形占中间那块圆角方形。
func draw(_ side: Int) -> Data? {
    let s = CGFloat(side)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // 底板：圆角方形，深色到更深的竖向渐变，与系统深色图标一族相称。
    let inset = s * 0.086
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = plate.width * 0.2237          // macOS 圆角比例
    let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let plateColors = [
        CGColor(colorSpace: space, components: [0.129, 0.153, 0.204, 1])!,
        CGColor(colorSpace: space, components: [0.067, 0.078, 0.110, 1])!,
    ]
    if let g = CGGradient(colorsSpace: space, colors: plateColors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    }
    ctx.restoreGState()

    // 环：起于左下 225°，逆时针走 270°，缺口朝正下方。
    let center = CGPoint(x: s / 2, y: s / 2)
    let ring = plate.width * 0.315
    let width = plate.width * 0.105
    let start = CGFloat.pi * 1.25
    let sweep = CGFloat.pi * 1.5

    ctx.setLineCap(.round)
    ctx.setLineWidth(width)
    ctx.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.16])!)
    ctx.addArc(center: center, radius: ring, startAngle: start, endAngle: start - sweep,
               clockwise: true)
    ctx.strokePath()

    // 已用弧取 0.62，让图标在任何尺寸下都是同一个可辨认的形状，不随实际额度变。
    ctx.setStrokeColor(CGColor(colorSpace: space, components: [0.298, 0.561, 1.0, 1])!)
    ctx.addArc(center: center, radius: ring, startAngle: start,
               endAngle: start - sweep * 0.62, clockwise: true)
    ctx.strokePath()

    // 中心指针：从圆心指向弧的末端，短而粗，小尺寸下仍看得出朝向。
    let angle = start - sweep * 0.62
    ctx.setLineWidth(width * 0.62)
    ctx.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.92])!)
    ctx.move(to: CGPoint(x: center.x + cos(angle) * ring * 0.18,
                         y: center.y + sin(angle) * ring * 0.18))
    ctx.addLine(to: CGPoint(x: center.x + cos(angle) * ring * 0.66,
                            y: center.y + sin(angle) * ring * 0.66))
    ctx.strokePath()

    ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.92])!)
    let dot = ring * 0.12
    ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))

    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: s, height: s)
    return rep.representation(using: .png, properties: [:])
}

// iconset 要求的十档尺寸，@2x 与下一档 @1x 同像素但文件名不同，须各写一份。
let wanted: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, side) in wanted {
    guard let png = draw(side) else {
        FileHandle.standardError.write(Data("绘制失败：\(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appending(path: "\(name).png"))
}

let icns = URL(fileURLWithPath: out).appending(path: "icon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil 失败\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("已生成 \(icns.path)")

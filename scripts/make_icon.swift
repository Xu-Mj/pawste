// Pawste 应用图标生成器
//
// 用 CoreGraphics 画 1024×1024 master：
//   - 圆角方块背景（留 macOS 标准边距）+ 蓝紫渐变 + 顶部柔光
//   - 白色猫爪：直接用 Apple 官方 SF Symbol `pawprint.fill`，一眼可辨、最简
//
// 输出透明背景 PNG（mac idiom 图标自带圆角，不需要系统再 mask）
//
// 用法：swift scripts/make_icon.swift <输出路径.png>

import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S = 1024

guard let ctx = CGContext(
    data: nil, width: S, height: S,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("无法创建 CGContext") }

let sf = CGFloat(S)

// MARK: - 背景圆角方块（蓝紫渐变 + 顶部柔光）

let margin: CGFloat = sf * 0.085
let rect = CGRect(x: margin, y: margin, width: sf - margin * 2, height: sf - margin * 2)
let radius = rect.width * 0.2237

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let gradient = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.42, green: 0.36, blue: 0.96, alpha: 1.0),  // indigo
    CGColor(red: 0.30, green: 0.55, blue: 1.00, alpha: 1.0),  // blue
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(glow,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.midY), options: [])
ctx.restoreGState()

// MARK: - 白色猫爪（SF Symbol pawprint.fill）

// 取配置好的符号图，按目标尺寸等比缩放，染成白色
let cfg = NSImage.SymbolConfiguration(pointSize: sf * 0.5, weight: .regular)
guard let base = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else {
    fatalError("找不到 SF Symbol pawprint.fill")
}

// 染白：sourceAtop 用白色覆盖符号的不透明区域
let paw = NSImage(size: base.size)
paw.lockFocus()
base.draw(in: NSRect(origin: .zero, size: base.size))
NSColor.white.set()
NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
paw.unlockFocus()

// 居中绘制（占画布约 56% 宽，等比；略微下移让重心居中）
let targetW = sf * 0.56
let scale = targetW / base.size.width
let pw = base.size.width * scale
let ph = base.size.height * scale
let pawRect = NSRect(x: (sf - pw) / 2, y: (sf - ph) / 2 - sf * 0.01, width: pw, height: ph)

let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsctx
paw.draw(in: pawRect)
NSGraphicsContext.restoreGraphicsState()

// MARK: - 导出 PNG

guard let image = ctx.makeImage() else { fatalError("makeImage 失败") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 编码失败") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("✅ 写出 \(outPath) (\(S)×\(S))")

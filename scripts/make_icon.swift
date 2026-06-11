// Pawste 应用图标生成器
//
// 用 CoreGraphics 画一张 1024×1024 master：
//   - 圆角方块背景（留 macOS 标准边距）+ 蓝紫渐变 + 顶部柔光
//   - 白色猫爪（1 主肉垫 + 4 趾豆），呼应 paw + paste 名字
//
// 输出透明背景 PNG（mac idiom 图标自带圆角，不需要系统再 mask）
//
// 用法：swift scripts/make_icon.swift <输出路径.png>

import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_1024.png"

let S = 1024  // 画布边长

guard let ctx = CGContext(
    data: nil,
    width: S, height: S,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("无法创建 CGContext")
}

let sf = CGFloat(S)

// MARK: - 背景圆角方块（留边距）

// macOS 图标内容约占画布 ~80%，四周留透明边距 + 自带圆角
let margin: CGFloat = sf * 0.085
let rect = CGRect(x: margin, y: margin, width: sf - margin * 2, height: sf - margin * 2)
let radius = rect.width * 0.2237   // Apple 连续圆角近似比例

let roundedPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(roundedPath)
ctx.clip()

// 蓝紫渐变（左上 → 右下）
let colors = [
    CGColor(red: 0.42, green: 0.36, blue: 0.96, alpha: 1.0),  // #6B5CF5 indigo
    CGColor(red: 0.30, green: 0.55, blue: 1.00, alpha: 1.0),  // #4D8CFF blue
] as CFArray
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: colors,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.minX, y: rect.maxY),   // 左上
    end: CGPoint(x: rect.maxX, y: rect.minY),     // 右下
    options: []
)

// 顶部柔光：增强立体感
let glow = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    glow,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.midY),
    options: []
)
ctx.restoreGState()

// MARK: - 猫爪（白色）

// 注意：CGContext 坐标系原点在左下角，y 向上
// 设计时以画布中心为参照，paw 整体略微下偏让趾豆在上、肉垫在下
let cx = sf / 2

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))

// 画一个（可旋转的）椭圆豆子
func bean(centerX: CGFloat, centerY: CGFloat, w: CGFloat, h: CGFloat, rotationDeg: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: centerX, y: centerY)
    ctx.rotate(by: rotationDeg * .pi / 180)
    let e = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    ctx.addEllipse(in: e)
    ctx.fillPath()
    ctx.restoreGState()
}

// 主肉垫：心形/水滴（宽圆顶 + 收窄圆底尖），用 cubic bezier 画一个干净的形
// 比叠椭圆干净，没有缺口
let pcx = cx
let pcy = sf * 0.36          // 肉垫中心（偏下）
let hw = sf * 0.185          // 半宽
let topY = pcy + sf * 0.135  // 顶部
let botY = pcy - sf * 0.175  // 底部尖
let path = CGMutablePath()
// 从左肩出发，绕一圈：左肩 → 顶（宽圆）→ 右肩 → 右下 → 底尖 → 左下 → 回左肩
path.move(to: CGPoint(x: pcx - hw, y: pcy + sf * 0.02))
// 上沿：左肩 → 顶部 → 右肩（一条饱满的凸弧）
path.addCurve(to: CGPoint(x: pcx + hw, y: pcy + sf * 0.02),
              control1: CGPoint(x: pcx - hw, y: topY + sf * 0.04),
              control2: CGPoint(x: pcx + hw, y: topY + sf * 0.04))
// 右侧：右肩 → 底尖
path.addCurve(to: CGPoint(x: pcx, y: botY),
              control1: CGPoint(x: pcx + hw, y: pcy - sf * 0.08),
              control2: CGPoint(x: pcx + sf * 0.06, y: botY))
// 左侧：底尖 → 左肩
path.addCurve(to: CGPoint(x: pcx - hw, y: pcy + sf * 0.02),
              control1: CGPoint(x: pcx - sf * 0.06, y: botY),
              control2: CGPoint(x: pcx - hw, y: pcy - sf * 0.08))
path.closeSubpath()
ctx.addPath(path)
ctx.fillPath()

// 4 个趾豆，沿弧线排在肉垫上方（内高外低、外侧向外倾）
let toeBaseY = sf * 0.60
let innerDX = sf * 0.095
let outerDX = sf * 0.205

// 内侧（高、近竖直）
bean(centerX: cx - innerDX, centerY: toeBaseY + sf * 0.05, w: sf * 0.14, h: sf * 0.185, rotationDeg: 10)
bean(centerX: cx + innerDX, centerY: toeBaseY + sf * 0.05, w: sf * 0.14, h: sf * 0.185, rotationDeg: -10)
// 外侧（低、向外倾、略小）
bean(centerX: cx - outerDX, centerY: toeBaseY - sf * 0.025, w: sf * 0.125, h: sf * 0.16, rotationDeg: 34)
bean(centerX: cx + outerDX, centerY: toeBaseY - sf * 0.025, w: sf * 0.125, h: sf * 0.16, rotationDeg: -34)

// MARK: - 导出 PNG

guard let image = ctx.makeImage() else { fatalError("makeImage 失败") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 编码失败") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("✅ 写出 \(outPath) (\(S)×\(S))")

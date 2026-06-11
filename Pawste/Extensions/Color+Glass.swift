import SwiftUI

// 浮窗里用的语义前景色（固定白色不透明度，不走 vibrancy）
//
// 为什么不用 SwiftUI 的 .secondary / .tertiary：
//   浮窗是 Liquid Glass（.glassEffect），SwiftUI 的层级色（.secondary/.tertiary/.primary）
//   会被系统的 vibrancy 拿"浮窗背后实时内容"做混合 —— 真实显示时常被冲淡到几乎看不见
//   （截图反而清楚就是这个原因；macOS 26/27 上更明显）。
//   显式不透明度颜色不参与 vibrancy，渲染稳定可控。
//
// 面板强制 .preferredColorScheme(.dark)，所以统一用白色不同透明度表达层级。
// 想整体调明暗，只改这三个值即可。
//
// 用法和系统层级色一致：.foregroundStyle(.glassSecondary) / Color.glassTertiary
extension ShapeStyle where Self == Color {
    static var glassPrimary: Color { .white.opacity(0.95) }    // 主要文字
    static var glassSecondary: Color { .white.opacity(0.68) }  // 次要文字 / 图标
    static var glassTertiary: Color { .white.opacity(0.48) }   // 辅助提示（footer、占位）
}

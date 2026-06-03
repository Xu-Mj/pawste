import SwiftUI
import AppKit

// Hover 时把光标变成手指（pointing hand）
//
// SwiftUI 没有原生 pointer cursor 修饰符，要用 onHover + NSCursor 实现
// 自定义 hit target（行、chip、自绘按钮等）用这个，标准 macOS 控件保持系统默认行为
// 风格参考 Raycast / Paste / Notion 等 macOS App
//
// 实现注意：
//   - 用 .set() 而不是 .push/.pop，前者幂等不会出现栈不平衡（嵌套时栈乱光标不恢复）
//   - 多个 .onHover 在同一 view 上会都触发，不影响已有的 isHovered 状态追踪
extension View {
    func pointerCursor() -> some View {
        onHover { hovering in
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

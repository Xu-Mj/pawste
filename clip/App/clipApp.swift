import SwiftUI

// SwiftUI App 入口，但实际工作交给 AppDelegate（AppKit）
//
// 为什么还保留 SwiftUI 的 @main App？
// - 方便将来加 Settings 窗口（用 Settings { } scene）
// - 保留 SwiftUI App 生命周期的好处（可以用 @Environment、@AppStorage 等）
// - AppKit 和 SwiftUI 不是非此即彼，可以混搭，这是 Apple 推荐的现代模式
@main
struct ClipApp: App {

    // @NSApplicationDelegateAdaptor：SwiftUI 和 AppKit 生命周期的官方桥梁
    // 它会创建一个 AppDelegate 实例，并把所有 NSApplicationDelegate 回调路由给它
    // 这是在 SwiftUI App 里使用 AppKit 老式 delegate 模式的标准做法
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 这里只是满足 App 协议"必须有至少一个 Scene"的要求
        // 实际偏好设置窗口由 StatusBarController 用 AppKit NSWindow 直接管理
        //
        // 为什么不用 Settings { SettingsView(...) }：
        //   - macOS 26 上 showSettingsWindow: selector 失效（变 no-op + 打 deprecation warning）
        //   - Apple 推荐的 SettingsLink 是 SwiftUI View，无法从 AppKit NSMenu 调用
        //   - 我们的 App 是 LSUIElement = YES（菜单栏 App），⌘, 也天然不工作
        //   - 综合考虑：完全弃用 Settings scene，AppKit NSWindow 完全可控
        Settings {
            EmptyView()
        }
    }
}

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
        // App 协议要求至少一个 Scene
        // Settings { } 是专门给"设置窗口"用的 scene，只在用户主动打开（如菜单栏的"偏好设置"）时才显示
        // 现在我们还没做设置 UI，先放个空 EmptyView 占位
        // 这意味着启动时没有任何窗口出现 —— 完美符合菜单栏 App 的语义
        Settings {
            EmptyView()
        }
    }
}

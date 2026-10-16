import AppKit
import ApplicationServices  // AXIsProcessTrusted / CGPreflightPostEventAccess 在这里

// 模拟 ⌘V 粘贴到当前前台 App 的工具
//
// enum 当命名空间用：Swift 里没成员的 enum 用作"静态工具集合"是惯用法
// 不能被实例化（enum 默认行为），比 class/struct 更明确表达"只是工具命名空间"
// 类似 Rust 里的 `mod` 但更轻量
enum Paster {

    // V 键的 macOS 虚拟键码
    // 不是 ASCII，是物理键位的硬件码。'V' 永远是 9，无论你是不是 QWERTY 布局
    // 完整键码表搜 "macOS HIToolbox Events.h"
    private static let vKeyCode: CGKeyCode = 9

    // MARK: - 辅助功能权限

    // 当前进程能否向其他 App 投递键盘事件（模拟 ⌘V 所需的权限）
    // 不弹框，只是查询。可以用来在 UI 上显示"请到设置开启权限"
    //
    // 为什么首选 CGPreflightPostEventAccess 而不是 AXIsProcessTrusted：
    // 我们只用 CGEvent.post，需要的是"投递事件"权限（TCC PostEvent），不是完整的 AX API 权限。
    // 旧版本开过 App Sandbox——沙盒 App 无法获得 AX 信任，AXIsProcessTrusted 永远返回 false，
    // 即使用户已在 系统设置 → 辅助功能 里勾选了也一样（"明明授权了还提示没授权"的根因）。
    // 现在沙盒已关，但仍按实际所需的 PostEvent 权限判断（沙盒内外都准确），
    // AX 信任同样意味着能投递事件，两者取或兜底。
    static var hasAccessibilityPermission: Bool {
        CGPreflightPostEventAccess() || AXIsProcessTrusted()
    }

    // 请求投递事件权限（首次会弹系统对话框引导用户去设置）
    // 用户必须手动到 系统设置 → 隐私与安全 → 辅助功能 里勾选我们的 App
    // 这是 macOS 强制的安全设计，App 不能绕过
    // 不用 AXIsProcessTrustedWithOptions(prompt:)：沙盒内它不弹框也拿不到权限
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        CGRequestPostEventAccess()
    }

    // MARK: - 模拟粘贴

    // 模拟按下 ⌘V 把剪贴板内容粘贴到当前前台 App
    // 调用前确保 NSPasteboard 已经有想要粘贴的内容
    static func simulatePaste() {
        guard hasAccessibilityPermission else {
            log("⚠️ 缺少辅助功能权限，无法自动粘贴")
            // 第一次调用时弹系统对话框，引导用户授权
            requestAccessibilityPermission()
            return
        }

        // CGEventSource：事件来源描述
        // .combinedSessionState 表示"参考整个会话的当前修饰键状态"，最常用的来源
        let source = CGEventSource(stateID: .combinedSessionState)

        // 创建两个事件：V 按下 + V 抬起，都带 ⌘ 修饰键
        // 注意：不需要单独发"⌘按下/抬起"事件，flags 已经包含了
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        down?.flags = .maskCommand

        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        up?.flags = .maskCommand

        // post(tap:) 把事件注入到指定位置的事件流
        // .cgAnnotatedSessionEventTap：会话级事件流，所有 App 都能收到
        // （还有 .cghidEventTap 是更底层的硬件层，通常不用）
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)

        log("📤 已模拟 ⌘V")
    }
}

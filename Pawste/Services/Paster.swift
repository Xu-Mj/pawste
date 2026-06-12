import AppKit
import ApplicationServices  // AXIsProcessTrusted 在这里

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

    // 当前进程是否被授予了辅助功能权限
    // 不弹框，只是查询。可以用来在 UI 上显示"请到设置开启权限"
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    // 请求辅助功能权限（弹出系统对话框引导用户去设置）
    // 用户必须手动到 系统设置 → 隐私与安全 → 辅助功能 里勾选我们的 App
    // 这是 macOS 强制的安全设计，App 不能绕过
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        // key = true：检查失败时自动弹系统提示对话框
        // 不直接引用 kAXTrustedCheckOptionPrompt：它在 C 头里声明成全局 var，
        // Swift 6 并发检查会报"shared mutable state"；其值是稳定的字面量，直接写出来
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
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

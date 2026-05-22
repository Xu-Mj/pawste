import AppKit

// 自定义 NSPanel 子类
//
// 问题：默认 borderless 风格的 NSPanel 不能成为 key window（无法接收键盘焦点）
// 表现：调 makeKeyAndOrderFront 会有 warning，Esc / 搜索框输入这些键盘事件收不到
//
// 解决：继承 NSPanel，覆写 canBecomeKey 返回 true
// 这是 AppKit 浮窗类工具的标准套路（Spotlight、Raycast、Maccy 都这么干)
//
// 注意命名：在 macOS 26+ / Xcode 26+，canBecomeKeyWindow 被重命名为 canBecomeKey
// （因为是 NSWindow 的属性，"Window" 后缀冗余）。老版本写 canBecomeKeyWindow 也能编译
final class FloatingPanel: NSPanel {

    // override：覆盖父类方法/属性。Swift 强制必须写 override 关键字，否则编译报错
    // 这点比 Java/C# 严格——防止意外重写
    override var canBecomeKey: Bool { true }

    // canBecomeMain 也覆写下
    // main window 是"主窗口"概念，菜单栏 App 一般不需要
    override var canBecomeMain: Bool { false }
}

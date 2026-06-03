import AppKit              // NSEvent.ModifierFlags 在 AppKit 里
import KeyboardShortcuts

// 集中管理所有全局快捷键的命名和默认值
//
// extension：扩展。给已有类型（这里是 KeyboardShortcuts.Name）添加新成员
// 类似 Rust 的 impl Block，但更灵活：可以扩展别人的类型，也能在 protocol 上扩展
//
// 为什么用扩展而不是写一个新的 enum？
// 因为 KeyboardShortcuts 库要求快捷键名字必须是 KeyboardShortcuts.Name 类型
// 扩展是 Swift 里给"外部类型"添加便捷成员的标准做法
extension KeyboardShortcuts.Name {

    // togglePawste：呼出/隐藏剪贴板浮窗
    //
    // Self("togglePawste", default: ...) 创建一个命名快捷键：
    //   - 第一个参数 "togglePawste" 是持久化的 key，存在 UserDefaults 里
    //     用户改快捷键后，库会以这个 key 记住偏好
    //   - default 是默认快捷键，用户没改时使用
    //
    // .init(.v, modifiers: [.option])：
    //   .v 是 KeyboardShortcuts.Key 枚举（系统键码的封装）
    //   .option 是 NSEvent.ModifierFlags 的子集（修饰键）
    //
    // 最终默认快捷键：⌥+V （和 Maccy 一致）
    static let togglePawste = Self(
        "togglePawste",
        default: .init(.v, modifiers: [.option])
    )
}

import Foundation

// 剪贴板历史中的单条记录
//
// struct：值类型。和 PasteboardWatcher（class）不同，这里用 struct 因为：
// - item 数据是"一份内容"概念，不需要共享身份
// - 不可变的、可拷贝的数据用 struct 更符合 Swift 风格
// - SwiftUI 的 ForEach/List 配合值类型工作得更好
//
// Identifiable：协议，约定有 id 属性，SwiftUI 用 id 追踪列表行
//   如果不实现 Identifiable，ForEach 必须显式指定 id 字段，写起来啰嗦
//
// Hashable：协议，让 struct 可以放进 Set 或当 Dictionary 的 key
//   也是 SwiftUI 某些场景的隐式要求（如 navigationDestination）
//
// Codable = Encodable + Decodable：自动支持 JSON / Plist 序列化
//   因为所有字段（UUID, String, Date）都已经 Codable，编译器自动合成实现
//   这是 Swift 类型系统最爽的地方之一——零样板拿到序列化能力
struct ClipboardItem: Identifiable, Hashable, Codable {

    // let：不可变（常量）。Rust 里的 let，对应 Swift 的 let
    // 想可变就写 var
    let id: UUID

    // 复制的文本内容。这一版只支持纯文本，将来加图片/文件时这里要改成 enum
    let text: String

    // 复制时间。将来 UI 显示"5 秒前"这种相对时间用
    let copiedAt: Date

    // 自定义构造函数
    // 不写也行（Swift 自动生成 memberwise init），但我们想统一让外部只传 text
    // id 和时间内部生成
    init(text: String) {
        self.id = UUID()
        self.text = text
        self.copiedAt = Date()  // Date() 不带参数 = 当前时间
    }
}

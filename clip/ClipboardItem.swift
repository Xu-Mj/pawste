import Foundation

// 剪贴板历史中的单条记录
//
// 用 Kind 枚举区分文本/图片：
//   - 类型安全，编译器强制穷举
//   - Codable 自动支持（Swift 5.5+ 对 enum with associated values 自动合成）
//
// id / copiedAt 是所有 kind 共有的元数据
struct ClipboardItem: Identifiable, Hashable, Codable {

    let id: UUID
    let kind: Kind
    let copiedAt: Date

    init(kind: Kind) {
        self.id = UUID()
        self.kind = kind
        self.copiedAt = Date()
    }

    enum Kind: Hashable, Codable {
        case text(String)
        case image(ImageEntry)
    }

    // 图片条目元数据
    //
    // 注意：原图二进制不存这里，只存元数据 + 缩略图
    // 原图存在磁盘 ~/Library/Application Support/Clip/images/<filename>
    struct ImageEntry: Hashable, Codable {
        // 我们自己的存储文件名，"<uuid>.png"，全局唯一
        let filename: String

        // 用户友好的显示名
        // - 来自文件复制时：原文件名（如 "screenshot.png"）
        // - 来自数据复制时：自动生成（如 "Screenshot_20260522_153022.png"）
        let displayName: String

        // 来源文件路径（如果是从 Finder 复制文件得到的）
        // - 用途 1：sourcePath 去重——同一个文件路径反复复制只算一次
        // - 用途 2：UI 右键"在 Finder 中显示"（将来扩展）
        let sourcePath: String?

        let width: Int
        let height: Int

        // 缩略图 PNG 数据，40×40 左右
        // 内联存进 JSON，启动加载即可用（不需要再去磁盘读原图）
        // Data 类型 Codable 自动 base64 编码
        let thumbnail: Data
    }
}

// 便利访问器：在 firstIndex(where:) 等场景下少写一堆 if case let
extension ClipboardItem.Kind {
    var asText: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    var asImage: ClipboardItem.ImageEntry? {
        if case .image(let e) = self { return e }
        return nil
    }
}

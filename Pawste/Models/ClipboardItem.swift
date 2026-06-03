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

    // 是否置顶。置顶条目：
    //   - 永远排在列表顶部
    //   - 不计入 maxItems / maxImages 容量限制
    //   - 不会被 evict 删除
    // var（不是 let）：用户能切换状态
    var isPinned: Bool

    init(kind: Kind) {
        self.id = UUID()
        self.kind = kind
        self.copiedAt = Date()
        self.isPinned = false
    }

    // 自定义 Decoder 支持向后兼容
    // 旧 JSON 没有 isPinned 字段，解码时默认 false
    // 新保存的 JSON 会包含这个字段（Encodable 自动合成不变）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.copiedAt = try c.decode(Date.self, forKey: .copiedAt)
        // try? 转 Optional，?? false 兜底——老数据没这字段就当未置顶
        self.isPinned = (try? c.decode(Bool.self, forKey: .isPinned)) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, copiedAt, isPinned
    }

    enum Kind: Hashable, Codable {
        case text(String)
        case image(ImageEntry)
    }

    // 图片条目元数据
    //
    // 注意：原图二进制不存这里，只存元数据 + 缩略图
    // 原图存在磁盘 ~/Library/Application Support/Pawste/images/<filename>
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

import AppKit
import Foundation

// 图片处理 Actor —— 所有耗时操作（解码/编码/写盘/生成缩略图）在这里完成
//
// 为什么用 actor 而不是普通 class：
//   1. 自动串行化：多次调用 process() 不会乱序，第一次没完第二次自动排队
//   2. 隔离主线程：actor 默认在自己的 executor 上跑，不阻塞 UI
//   3. Swift 编译器保证线程安全，不用自己写锁
//
// 用法：
//   let entry = await imageProcessor.process(data: ..., sourcePath: ...)
//   // 这里已经回到主线程（如果调用方是 @MainActor）
actor ImageProcessor {

    // 缩略图目标尺寸
    private static let thumbnailSize: CGFloat = 40

    // 单图最大字节数（50MB），超过直接拒绝
    private static let maxImageBytes = 50 * 1024 * 1024

    // 图片存储目录
    private let imagesDir: URL

    init(imagesDir: URL) {
        self.imagesDir = imagesDir
        // 确保目录存在
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    // MARK: - 主入口

    // 处理一份图片数据，返回可以存进 items 数组的 ImageEntry
    // 返回 nil 表示处理失败（解码失败 / 超大 / 写盘失败等）
    func process(data: Data, sourcePath: String?) -> ClipboardItem.ImageEntry? {
        // 1. 尺寸预检：超大图直接拒绝
        guard data.count <= Self.maxImageBytes else {
            print("⚠️ 图片过大（\(data.count / 1024 / 1024)MB），跳过")
            return nil
        }

        // 2. 解码（兼容 PNG/JPEG/TIFF/GIF/BMP/HEIC 等 NSImage 支持的所有格式）
        guard let nsImage = NSImage(data: data) else {
            print("⚠️ 图片解码失败")
            return nil
        }
        let size = nsImage.size
        guard size.width > 0, size.height > 0 else {
            print("⚠️ 图片尺寸异常")
            return nil
        }

        // 3. 归一化到 PNG，写盘
        // 用 UUID 当文件名，避免冲突
        guard let pngData = nsImage.pngRepresentation() else {
            print("⚠️ PNG 编码失败")
            return nil
        }

        let filename = "\(UUID().uuidString).png"
        let fileURL = imagesDir.appendingPathComponent(filename)

        do {
            // .atomic：先写临时文件再 rename，断电也不会留半截
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ 写图片文件失败: \(error.localizedDescription)")
            return nil
        }

        // 4. 生成缩略图
        let thumbnailData = makeThumbnail(from: nsImage)

        // 5. 算 displayName
        let displayName = computeDisplayName(sourcePath: sourcePath)

        print("➕ 图片入库: \(displayName) (\(Int(size.width))×\(Int(size.height)), \(data.count / 1024)KB)")

        return ClipboardItem.ImageEntry(
            filename: filename,
            displayName: displayName,
            sourcePath: sourcePath,
            width: Int(size.width),
            height: Int(size.height),
            thumbnail: thumbnailData
        )
    }

    // 删除某个图片文件（当 item 被 evict 时调用）
    func deleteFile(filename: String) {
        let url = imagesDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    // 给一个 ImageEntry 加载完整 PNG 数据（粘贴时调用）
    func loadFullImageData(filename: String) -> Data? {
        let url = imagesDir.appendingPathComponent(filename)
        return try? Data(contentsOf: url)
    }

    // MARK: - 辅助

    // 等比缩放生成 40×40 缩略图（短边贴齐 40，长边居中裁剪）
    private func makeThumbnail(from image: NSImage) -> Data {
        let target = CGSize(width: Self.thumbnailSize, height: Self.thumbnailSize)
        let thumb = NSImage(size: target)
        thumb.lockFocus()

        // 等比 fit + 居中
        // 这里用 fit 而不是 fill，避免裁掉重要内容
        let aspect = image.size.width / image.size.height
        let drawRect: CGRect
        if aspect > 1 {
            // 横图：限定宽度
            let h = target.width / aspect
            drawRect = CGRect(x: 0, y: (target.height - h) / 2, width: target.width, height: h)
        } else {
            // 竖图：限定高度
            let w = target.height * aspect
            drawRect = CGRect(x: (target.width - w) / 2, y: 0, width: w, height: target.height)
        }
        image.draw(in: drawRect)
        thumb.unlockFocus()

        return thumb.pngRepresentation() ?? Data()
    }

    private func computeDisplayName(sourcePath: String?) -> String {
        if let path = sourcePath {
            // 从路径取文件名
            return (path as NSString).lastPathComponent
        }
        // 自动生成名字（按截图工具的习惯）
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "Screenshot_\(formatter.string(from: Date())).png"
    }
}

// MARK: - NSImage → PNG 数据扩展

extension NSImage {
    // 把 NSImage 编码成 PNG 二进制
    // tiffRepresentation 是 NSImage 的"原始位图数据"接口（不管你内部是啥格式）
    // 再走 NSBitmapImageRep 转成 PNG
    func pngRepresentation() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

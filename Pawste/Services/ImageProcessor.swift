import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// 图片处理 Actor —— 所有耗时操作（解码/编码/写盘/生成缩略图）在这里完成
//
// 为什么用 actor：
//   1. 自动串行化：多次 process() 排队，不乱序
//   2. 隔离主线程：在自己的 executor（后台）跑，不阻塞 UI
//
// 为什么用 ImageIO/CoreGraphics 而不是 NSImage：
//   NSImage / NSBitmapImageRep / lockFocus 在 Swift 6 严格并发下是 main-actor 隔离，
//   在后台 actor 上调用是正确性灰区（编译告警，且 lockFocus 离开主线程本就不安全）。
//   CGImageSource / CGImageDestination 线程安全、非隔离，正是为后台解码/缩略图设计的。
actor ImageProcessor {

    // 缩略图最长边像素（保留纵横比，不强制正方形——展示侧自己缩放）
    private static let thumbnailMaxPixel = 40

    // 单图最大字节数（50MB），超过直接拒绝
    private static let maxImageBytes = 50 * 1024 * 1024

    private let imagesDir: URL

    // 数据型图片（截图等）兜底显示名的格式器
    // DateFormatter 构造是毫秒级开销，缓存复用；actor 隔离保证线程安全
    private let screenshotNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    init(imagesDir: URL) {
        self.imagesDir = imagesDir
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    // MARK: - 主入口

    // 处理剪贴板里的图片数据（截图、网页复制等），返回可存进 items 的 ImageEntry；失败返回 nil
    func process(data: Data) -> ClipboardItem.ImageEntry? {
        guard data.count <= Self.maxImageBytes else {
            log("⚠️ 图片过大（\(data.count / 1024 / 1024)MB），跳过")
            return nil
        }

        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0 else {
            log("⚠️ 图片解码失败")
            return nil
        }

        // 已是 PNG（系统截图、网页复制的最常见情况）：原始数据直写，
        // 跳过"解全图 + 重编码"这两步最重的操作
        let strategy: WriteStrategy = Self.isPNG(src) ? .writeData(data) : .transcode
        return makeEntry(from: src, sourcePath: nil, originalBytes: data.count, strategy: strategy)
    }

    // 处理 Finder 复制的图片文件
    // 直接从 URL 建 CGImageSource：原图不经过主线程，也不必整个读进内存
    //（PNG 文件直接 copyItem，ImageIO 读尺寸/缩略图只取需要的字节）
    func processFile(at url: URL) -> ClipboardItem.ImageEntry? {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard bytes <= Self.maxImageBytes else {
            log("⚠️ 图片文件过大（\(bytes / 1024 / 1024)MB），跳过")
            return nil
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else {
            log("⚠️ 图片文件解码失败: \(url.path)")
            return nil
        }

        // PNG 文件直接 copy，不过解码管线
        let strategy: WriteStrategy = Self.isPNG(src) ? .copyFile(url) : .transcode
        return makeEntry(from: src, sourcePath: url.path, originalBytes: bytes, strategy: strategy)
    }

    // 删除某个图片文件（item 被 evict / 删除时调用）
    func deleteFile(filename: String) {
        let url = imagesDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    // 加载完整 PNG 数据（粘贴时调用）
    func loadFullImageData(filename: String) -> Data? {
        let url = imagesDir.appendingPathComponent(filename)
        return try? Data(contentsOf: url)
    }

    // MARK: - 共享管线

    // 原图落盘策略：已是 PNG 的来源直接搬运字节，其余走解码重编码
    // nonisolated：纯数据，构造点跨 actor/MainActor（默认隔离会把嵌套类型绑到 MainActor）
    private nonisolated enum WriteStrategy {
        case writeData(Data)   // 剪贴板里的 PNG 数据，原样写盘
        case copyFile(URL)     // 磁盘上的 PNG 文件，直接 copy
        case transcode         // 非 PNG：解码 → PNG 重编码
    }

    // 两个入口共用的后半段：读尺寸 → 按策略写盘 → 缩略图 + 显示名
    private func makeEntry(
        from src: CGImageSource,
        sourcePath: String?,
        originalBytes: Int,
        strategy: WriteStrategy
    ) -> ClipboardItem.ImageEntry? {
        // 读像素尺寸（只读 metadata，不解码全图）
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            log("⚠️ 图片尺寸异常")
            return nil
        }

        let filename = "\(UUID().uuidString).png"
        let fileURL = imagesDir.appendingPathComponent(filename)
        do {
            switch strategy {
            case .writeData(let data):
                // .atomic：先写临时文件再 rename，断电不留半截
                try data.write(to: fileURL, options: .atomic)
            case .copyFile(let url):
                try FileManager.default.copyItem(at: url, to: fileURL)
            case .transcode:
                try transcodeToPNG(src, to: fileURL)
            }
        } catch {
            log("⚠️ 写图片文件失败: \(error.localizedDescription)")
            return nil
        }

        let thumbnailData = makeThumbnail(from: src) ?? Data()
        let displayName = computeDisplayName(sourcePath: sourcePath)

        log("➕ 图片入库: \(displayName) (\(width)×\(height), \(originalBytes / 1024)KB)")

        return ClipboardItem.ImageEntry(
            filename: filename,
            displayName: displayName,
            sourcePath: sourcePath,
            width: width,
            height: height,
            thumbnail: thumbnailData
        )
    }

    // nonisolated：默认隔离会把 actor 的 static 落到 MainActor，
    // 从 actor 里调用就成了跨隔离传 CGImageSource；查询函数本身线程安全
    private nonisolated static func isPNG(_ src: CGImageSource) -> Bool {
        guard let type = CGImageSourceGetType(src) else { return false }
        return UTType(type as String) == .png
    }

    // MARK: - 编码 / 缩略图

    // 非 PNG 源（TIFF/JPEG/HEIC 等）：解出完整 CGImage → 归一化编码成 PNG 写盘
    private func transcodeToPNG(_ src: CGImageSource, to fileURL: URL) throws {
        guard let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let pngData = encodePNG(cgImage) else {
            throw EncodeError()
        }
        try pngData.write(to: fileURL, options: .atomic)
    }

    private nonisolated struct EncodeError: Error, LocalizedError {
        var errorDescription: String? { "PNG 编码失败" }
    }

    // CGImage → PNG Data
    private func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // 生成缩略图 PNG（最长边 40px，保留纵横比 + EXIF 方向）
    // CGImageSourceCreateThumbnailAtIndex 直接由 source 高效降采样，不用先解全图再缩
    private func makeThumbnail(from src: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        return encodePNG(thumb)
    }

    private func computeDisplayName(sourcePath: String?) -> String {
        if let path = sourcePath {
            return (path as NSString).lastPathComponent
        }
        return "Screenshot_\(screenshotNameFormatter.string(from: Date())).png"
    }
}

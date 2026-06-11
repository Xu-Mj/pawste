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

    init(imagesDir: URL) {
        self.imagesDir = imagesDir
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    // MARK: - 主入口

    // 处理一份图片数据，返回可存进 items 的 ImageEntry；失败返回 nil
    func process(data: Data, sourcePath: String?) -> ClipboardItem.ImageEntry? {
        // 1. 尺寸预检
        guard data.count <= Self.maxImageBytes else {
            log("⚠️ 图片过大（\(data.count / 1024 / 1024)MB），跳过")
            return nil
        }

        // 2. 建 source（兼容 PNG/JPEG/TIFF/GIF/BMP/HEIC 等 ImageIO 支持的所有格式）
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0 else {
            log("⚠️ 图片解码失败")
            return nil
        }

        // 3. 读像素尺寸（只读 metadata，不解码全图）
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            log("⚠️ 图片尺寸异常")
            return nil
        }

        // 4. 解出完整 CGImage → 归一化编码成 PNG
        guard let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let pngData = encodePNG(cgImage) else {
            log("⚠️ PNG 编码失败")
            return nil
        }

        // 5. 写盘（.atomic：先写临时文件再 rename，断电不留半截）
        let filename = "\(UUID().uuidString).png"
        let fileURL = imagesDir.appendingPathComponent(filename)
        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            log("⚠️ 写图片文件失败: \(error.localizedDescription)")
            return nil
        }

        // 6. 缩略图 + displayName
        let thumbnailData = makeThumbnail(from: src) ?? Data()
        let displayName = computeDisplayName(sourcePath: sourcePath)

        log("➕ 图片入库: \(displayName) (\(width)×\(height), \(data.count / 1024)KB)")

        return ClipboardItem.ImageEntry(
            filename: filename,
            displayName: displayName,
            sourcePath: sourcePath,
            width: width,
            height: height,
            thumbnail: thumbnailData
        )
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

    // MARK: - 编码 / 缩略图

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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "Screenshot_\(formatter.string(from: Date())).png"
    }
}

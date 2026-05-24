import AppKit
import Observation
import Foundation

@Observable
final class PasteboardWatcher {

    // MARK: - 状态

    private(set) var items: [ClipboardItem] = []

    // 是否正在异步处理图片（UI 用来显示 loading 占位条）
    private(set) var isProcessingImage: Bool = false

    private(set) var maxItems: Int

    // MARK: - 内部状态

    private var lastChangeCount: Int
    private var timer: Timer?
    private let pollingInterval: TimeInterval = 0.3

    // 邻接去重用的轻量指纹（只跟"上一次"比）
    // 比全局 SHA256 便宜两个数量级
    private var lastImageSize: Int?
    private var lastImagePrefix: Data?

    // 图片处理器（actor，自动串行 + 后台线程）
    private let imageProcessor: ImageProcessor

    // MARK: - 持久化

    private static let maxItemsKey = "maxItems"
    private static let defaultMaxItems = 100

    // 图片数量上限，从 UserDefaults 读，默认 20
    // 文本几 KB 一条无所谓，图片每张几百 KB，单独限制
    private(set) var maxImages: Int

    private static let maxImagesKey = "maxImages"
    private static let defaultMaxImages = 20

    private static let appDir: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport.appendingPathComponent("Clip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let storeURL: URL = appDir.appendingPathComponent("history.json")

    private static let imagesDir: URL = appDir.appendingPathComponent("images", isDirectory: true)

    private var pendingSaveTask: Task<Void, Never>?

    // MARK: - 生命周期

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.maxItemsKey)
        self.maxItems = stored > 0 ? stored : Self.defaultMaxItems

        let storedImages = UserDefaults.standard.integer(forKey: Self.maxImagesKey)
        self.maxImages = storedImages > 0 ? storedImages : Self.defaultMaxImages

        self.lastChangeCount = NSPasteboard.general.changeCount
        self.imageProcessor = ImageProcessor(imagesDir: Self.imagesDir)

        loadFromDisk()
    }

    deinit {
        timer?.invalidate()
        print("🗑️ PasteboardWatcher 已释放")
    }

    // MARK: - 公开 API

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
        print("📋 PasteboardWatcher 启动，轮询 \(Int(pollingInterval * 1000))ms，容量 \(maxItems)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func clear() {
        // 清空 items 前，把所有图片文件也删了
        let imageFilenames = items.compactMap { $0.kind.asImage?.filename }
        items.removeAll()
        lastImageSize = nil
        lastImagePrefix = nil

        Task { [imageProcessor] in
            for filename in imageFilenames {
                await imageProcessor.deleteFile(filename: filename)
            }
        }
        print("🗑️ 历史已清空")
        scheduleSave()
    }

    func setMaxItems(_ n: Int) {
        guard n > 0, n != maxItems else { return }
        self.maxItems = n
        UserDefaults.standard.set(n, forKey: Self.maxItemsKey)
        evictIfNeeded()  // 复用统一的裁剪逻辑，图片文件连带删
        scheduleSave()
        print("📐 文本上限改为 \(n)")
    }

    func setMaxImages(_ n: Int) {
        guard n > 0, n != maxImages else { return }
        self.maxImages = n
        UserDefaults.standard.set(n, forKey: Self.maxImagesKey)
        evictIfNeeded()
        scheduleSave()
        print("🖼️ 图片上限改为 \(n)")
    }

    func flushSave() {
        pendingSaveTask?.cancel()
        saveNow()
    }

    // 给 UI / paste-back 用：根据 filename 拿到完整 PNG 数据
    func loadImageData(filename: String) async -> Data? {
        await imageProcessor.loadFullImageData(filename: filename)
    }

    // MARK: - 持久化逻辑

    private func loadFromDisk() {
        do {
            let data = try Data(contentsOf: Self.storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([ClipboardItem].self, from: data)
            items = decoded
            // 应用容量上限（总数 + 图片数），可能旧数据超出新设的上限
            // 这里会顺带删掉超额图片的磁盘文件
            evictIfNeeded()
            print("📂 加载历史 \(items.count) 条（其中图片 \(imageCount) 张）")
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            print("📂 首次启动，无历史文件")
        } catch {
            // 解码失败大概率是 schema 不兼容（旧版纯文本格式）
            // 直接清掉重来——用户已同意此策略
            print("⚠️ 历史文件解码失败，清空重来: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: Self.storeURL)
            items = []
        }
    }

    private func saveNow() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: Self.storeURL, options: .atomic)
        } catch {
            print("⚠️ 保存历史失败: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    // MARK: - 检测主循环

    private func check() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // 优先级：
        //   1. 文件 URL 指向图片 → 图片（带 sourcePath，能精准去重）
        //   2. 图片数据（screenshot / 网页复制等）
        //   3. 纯文本

        if let (data, path) = readImageFromFile(pb) {
            handleImage(data: data, sourcePath: path)
            return
        }

        if let data = readImageData(pb) {
            handleImage(data: data, sourcePath: nil)
            return
        }

        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addText(text)
            return
        }

        print("📋 [\(current)] 剪贴板变化，但没有可识别的内容")
    }

    // MARK: - 读取剪贴板

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "heic", "heif", "webp"
    ]

    // 检测 "用户从 Finder 复制了一个图片文件"：剪贴板有 fileURL
    // 返回 (图片数据, 文件路径)；不是图片文件则返回 nil
    private func readImageFromFile(_ pb: NSPasteboard) -> (Data, String)? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return nil
        }
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard Self.imageExtensions.contains(ext) else { continue }
            // 读文件内容
            guard let data = try? Data(contentsOf: url) else { continue }
            return (data, url.path)
        }
        return nil
    }

    // 检测纯图片数据
    private func readImageData(_ pb: NSPasteboard) -> Data? {
        // 按优先级尝试常见类型
        // PNG 最常见（系统截图、网页右键复制图片）
        // TIFF 是 macOS 内部默认（NSImage 写剪贴板时用）
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for type in types {
            if let data = pb.data(forType: type) {
                return data
            }
        }
        return nil
    }

    // MARK: - 处理逻辑：文本

    private func addText(_ text: String) {
        if let existingIndex = items.firstIndex(where: { $0.kind.asText == text }) {
            let existing = items.remove(at: existingIndex)
            items.insert(existing, at: 0)
            print("🔄 重排文本到顶部")
        } else {
            items.insert(ClipboardItem(kind: .text(text)), at: 0)
            evictIfNeeded()
            print("➕ 新文本 (共 \(items.count) 条)")
        }
        // 文本路径清掉图片指纹，避免误判
        lastImageSize = nil
        lastImagePrefix = nil
        scheduleSave()
    }

    // MARK: - 处理逻辑：图片

    private func handleImage(data: Data, sourcePath: String?) {
        // === 去重层 1：sourcePath（精准、便宜）===
        // 用户在 Finder 反复按 ⌘C 同一个文件 → path 一致 → 直接挪到顶
        if let path = sourcePath,
           let existingIndex = items.firstIndex(where: { $0.kind.asImage?.sourcePath == path }) {
            let existing = items.remove(at: existingIndex)
            items.insert(existing, at: 0)
            print("🔄 重排图片（按 sourcePath）到顶部: \(path)")
            scheduleSave()
            return
        }

        // === 去重层 2：邻接指纹（针对截图等纯数据复制）===
        // 只跟"上一次"比，O(1) 检测最常见的"误按两次 ⌘C"
        if data.count == lastImageSize,
           data.prefix(256) == lastImagePrefix {
            print("🔄 邻接重复图片，已忽略")
            return
        }

        // 更新指纹
        lastImageSize = data.count
        lastImagePrefix = data.prefix(256)

        // === 进入异步处理 ===
        isProcessingImage = true

        // Task @MainActor：以主线程为起点
        // await imageProcessor.process(...) 内部切到 actor 的 executor（后台）
        // 处理完成后自动回主线程（因为我们是 @MainActor）
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isProcessingImage = false }

            guard let entry = await self.imageProcessor.process(data: data, sourcePath: sourcePath) else {
                return
            }

            // 这里已经回到主线程，安全修改 items
            let item = ClipboardItem(kind: .image(entry))
            self.items.insert(item, at: 0)
            self.evictIfNeeded()
            self.scheduleSave()
        }
    }

    // MARK: - 容量管理

    // 同时执行两条容量规则：
    //   1. 图片数 > maxImages → 删最老的图片
    //   2. 总条数 > maxItems → 删最末（最老的，不分类型）
    //
    // 顺序先图片再总数：避免"先按总数删了一张图片"再发现还得删另一张
    private func evictIfNeeded() {
        // 规则 1：图片数量上限
        // items 是 newest-first，所以 lastIndex(where:) 找到的是最老的图片
        while imageCount > maxImages {
            guard let oldestImageIndex = items.lastIndex(where: { $0.kind.asImage != nil }) else {
                break  // 没图片可删了（理论不会发生，防御写法）
            }
            removeItem(at: oldestImageIndex)
        }

        // 规则 2：总数上限
        while items.count > maxItems {
            removeItem(at: items.count - 1)
        }
    }

    // 删除指定 index 的 item，如果是图片同时删磁盘文件
    private func removeItem(at index: Int) {
        let removed = items.remove(at: index)
        if let entry = removed.kind.asImage {
            let filename = entry.filename
            Task { [imageProcessor] in
                await imageProcessor.deleteFile(filename: filename)
            }
        }
    }

    // 当前图片条目数
    // 用 lazy 避免创建中间数组（小数据集影响微乎其微，但好习惯）
    private var imageCount: Int {
        items.lazy.filter { $0.kind.asImage != nil }.count
    }
}

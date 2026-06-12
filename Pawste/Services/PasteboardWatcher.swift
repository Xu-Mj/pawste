import AppKit
import Observation
import Foundation

@Observable
final class PasteboardWatcher {

    // MARK: - 状态

    private(set) var items: [ClipboardItem] = []

    // 正在异步处理的图片数量（UI 用 isProcessingImage 显示 loading 占位条）
    // 计数而非 Bool：两张图先后进入处理时，第一张完成不会提前关掉第二张的占位条
    private var processingCount = 0
    var isProcessingImage: Bool { processingCount > 0 }

    // MARK: - 内部状态

    private var lastChangeCount: Int
    private var timer: Timer?
    private let pollingInterval: TimeInterval = 0.3

    // 邻接去重用的轻量指纹（只跟"上一次数据型图片"比）
    // 比全局 SHA256 便宜两个数量级
    private var lastImageSize: Int?
    private var lastImagePrefix: Data?

    // 图片处理器（actor，自动串行 + 后台线程）
    private let imageProcessor: ImageProcessor

    // MARK: - 容量设置（UserDefaults 持久化）

    private enum SettingKey {
        static let maxItems = "maxItems"
        static let maxImages = "maxImages"
        static let maxPinned = "maxPinned"
    }

    private(set) var maxItems: Int

    // 图片数量上限：文本几 KB 一条无所谓，图片每张几百 KB，单独限制
    private(set) var maxImages: Int

    // 置顶条数上限（可配）
    private(set) var maxPinned: Int

    // 单条文本上限（5MB）：超大文本（整页日志等）会拖慢搜索过滤和 JSON 全量落盘，
    // 直接不收录（和图片 maxImageBytes 的"超限拒绝"策略一致，绝不截断——粘贴必须是原文）
    private static let maxTextBytes = 5 * 1024 * 1024

    // 持久化委托给 HistoryStore（编解码 + 防抖写盘 + 文件路径）
    private let store = HistoryStore()

    // MARK: - 生命周期

    init() {
        self.maxItems = Self.storedLimit(SettingKey.maxItems, default: 100)
        self.maxImages = Self.storedLimit(SettingKey.maxImages, default: 20)
        self.maxPinned = Self.storedLimit(SettingKey.maxPinned, default: 5)

        self.lastChangeCount = NSPasteboard.general.changeCount
        self.imageProcessor = ImageProcessor(imagesDir: HistoryStore.imagesDir)

        // 从磁盘加载 + 应用容量上限（旧数据可能超出新设上限，顺带删超额图片文件）
        items = store.load()
        evictIfNeeded()
        log("📂 加载历史 \(items.count) 条（其中图片 \(imageCount) 张）")
    }

    // MARK: - 公开 API

    func start() {
        guard timer == nil else { return }
        // Timer block 是 @Sendable，但 scheduledTimer 注册在主 RunLoop、只会在主线程触发，
        // assumeIsolated 把这一事实告诉编译器（错了会在运行时 trap，而不是静默数据竞争）
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check()
            }
        }
        log("📋 PasteboardWatcher 启动，轮询 \(Int(pollingInterval * 1000))ms，容量 \(maxItems)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // 切换某条历史的置顶状态
    //
    // 置顶 → 移到列表最顶（置顶组的开头）
    // 取消置顶 → 移到"非置顶组"的开头（即所有现有置顶项之后的第一位）
    //
    // 返回 false：当前没有该 ID / 已达置顶上限无法再置顶
    @discardableResult
    func togglePin(id: ClipboardItem.ID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return false
        }

        // 检查上限：如果当前非置顶 + 已经达到 maxPinned → 静默拒绝
        if !items[index].isPinned && pinnedCount >= maxPinned {
            log("⚠️ 置顶已满（\(maxPinned) 条），无法再置顶")
            return false
        }

        var item = items.remove(at: index)
        item.isPinned.toggle()
        insertAtGroupHead(item)
        log(item.isPinned ? "📌 已置顶 (共 \(pinnedCount) 条)" : "📌 已取消置顶")

        scheduleSave()
        return true
    }

    // 获取所有置顶条目（按当前顺序）
    var pinnedItems: [ClipboardItem] {
        items.filter { $0.isPinned }
    }

    // 获取所有非置顶条目（按当前顺序）
    var unpinnedItems: [ClipboardItem] {
        items.filter { !$0.isPinned }
    }

    // 删除单条历史
    // 返回值：删除成功（true）/ 没找到（false）
    // 删除图片条目时会连带删磁盘文件
    @discardableResult
    func deleteItem(id: ClipboardItem.ID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let removed = items.remove(at: index)

        // 图片类型：删磁盘文件
        if let entry = removed.kind.asImage {
            let filename = entry.filename
            Task { [imageProcessor] in
                await imageProcessor.deleteFile(filename: filename)
            }
        }

        // 如果删的是最近一张图（指纹还在），清掉指纹避免下次复制相同内容被误判为重复
        if removed.kind.asImage != nil {
            lastImageSize = nil
            lastImagePrefix = nil
        }

        log("🗑️ 删除条目（剩 \(items.count) 条）")
        scheduleSave()
        return true
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
        log("🗑️ 历史已清空")
        scheduleSave()
    }

    func setMaxItems(_ n: Int) {
        guard updateLimit(&maxItems, to: n, key: SettingKey.maxItems) else { return }
        evictIfNeeded()  // 复用统一的裁剪逻辑，图片文件连带删
        scheduleSave()
        log("📐 文本上限改为 \(n)")
    }

    func setMaxImages(_ n: Int) {
        guard updateLimit(&maxImages, to: n, key: SettingKey.maxImages) else { return }
        evictIfNeeded()
        scheduleSave()
        log("🖼️ 图片上限改为 \(n)")
    }

    func setMaxPinned(_ n: Int) {
        guard updateLimit(&maxPinned, to: n, key: SettingKey.maxPinned) else { return }
        log("📌 置顶上限改为 \(n)")
        // 如果当前已置顶数 > 新上限，超出部分取消置顶（最末的先）
        // 这样用户调小上限不会出现"超出但还显示着"的尴尬状态
        while pinnedCount > maxPinned {
            guard let lastPinnedIndex = items.lastIndex(where: { $0.isPinned }) else { break }
            var item = items.remove(at: lastPinnedIndex)
            item.isPinned = false
            insertAtGroupHead(item)
        }
        scheduleSave()
    }

    // 退出时同步落盘，确保防抖窗口里最后的变更不丢
    func flushSave() {
        store.flush(items)
    }

    // 给 UI / paste-back 用：根据 filename 拿到完整 PNG 数据
    func loadImageData(filename: String) async -> Data? {
        await imageProcessor.loadFullImageData(filename: filename)
    }

    // MARK: - 设置持久化辅助

    // 读 UserDefaults 里的上限值，没存过（0）用默认
    private static func storedLimit(_ key: String, default defaultValue: Int) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored > 0 ? stored : defaultValue
    }

    // 三个上限 setter 的公共骨架：校验 + 赋值 + 持久化；返回是否真的变了
    private func updateLimit(_ limit: inout Int, to n: Int, key: String) -> Bool {
        guard n > 0, n != limit else { return false }
        limit = n
        UserDefaults.standard.set(n, forKey: key)
        return true
    }

    // 防抖保存当前 items 快照
    private func scheduleSave() {
        store.scheduleSave(items)
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

        if let url = readImageFileURL(pb) {
            handleImageFile(url)
            return
        }

        if let data = readImageData(pb) {
            handleImageData(data)
            return
        }

        if let text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addText(text)
            return
        }

        log("📋 [\(current)] 剪贴板变化，但没有可识别的内容")
    }

    // MARK: - 读取剪贴板

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "heic", "heif", "webp"
    ]

    // 检测"用户从 Finder 复制了一个图片文件"：剪贴板有指向图片的 fileURL
    //
    // 只做扩展名 + 可读性检查，不在主线程读文件内容——
    // 大图的实际读取在 ImageProcessor（后台 actor）里完成
    //
    // 注意：多选复制多个图片文件时只收录第一个（刻意取舍：保持"一次复制 = 一条历史"的模型）
    private func readImageFileURL(_ pb: NSPasteboard) -> URL? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return nil
        }
        return urls.first { url in
            Self.imageExtensions.contains(url.pathExtension.lowercased())
                && FileManager.default.isReadableFile(atPath: url.path)
        }
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
        // 任何文本复制都打断图片"邻接"（即使下面因过大被跳过），指纹只描述上一次数据型图片
        lastImageSize = nil
        lastImagePrefix = nil

        guard text.utf8.count <= Self.maxTextBytes else {
            log("⚠️ 文本过大（\(text.utf8.count / 1024 / 1024)MB），不收录")
            return
        }

        if let existingIndex = items.firstIndex(where: { $0.kind.asText == text }) {
            // 已存在：保留 isPinned 状态，移到所属组的开头
            insertAtGroupHead(items.remove(at: existingIndex))
            log("🔄 重排文本到顶部")
        } else {
            // 新内容总是非置顶，落在"非置顶组"的开头
            insertAtGroupHead(ClipboardItem(kind: .text(text)))
            evictIfNeeded()
            log("➕ 新文本 (共 \(items.count) 条)")
        }
        scheduleSave()
    }

    // MARK: - 处理逻辑：图片

    // Finder 复制的图片文件：sourcePath 去重（精准、便宜）后交给 actor 处理
    private func handleImageFile(_ url: URL) {
        // 用户在 Finder 反复按 ⌘C 同一个文件 → path 一致 → 直接挪回组头
        let path = url.path
        if let existingIndex = items.firstIndex(where: { $0.kind.asImage?.sourcePath == path }) {
            insertAtGroupHead(items.remove(at: existingIndex))
            log("🔄 重排图片（按 sourcePath）到顶部: \(path)")
            scheduleSave()
            return
        }

        // 文件复制打断"邻接"：指纹只描述上一次数据型图片
        lastImageSize = nil
        lastImagePrefix = nil

        runImageProcessing { [imageProcessor] in
            await imageProcessor.processFile(at: url)
        }
    }

    // 数据型图片（截图、网页复制等）：邻接指纹去重后交给 actor 处理
    private func handleImageData(_ data: Data) {
        // 只跟"上一次"比，O(1) 检测最常见的"误按两次 ⌘C"
        if data.count == lastImageSize,
           data.prefix(256) == lastImagePrefix {
            log("🔄 邻接重复图片，已忽略")
            return
        }

        // 更新指纹
        lastImageSize = data.count
        lastImagePrefix = data.prefix(256)

        runImageProcessing { [imageProcessor] in
            await imageProcessor.process(data: data)
        }
    }

    // 两条图片路径共用的异步骨架：计数 → actor 处理 → 回主线程入列表
    private func runImageProcessing(_ process: @escaping () async -> ClipboardItem.ImageEntry?) {
        processingCount += 1

        // Task @MainActor：以主线程为起点
        // await process() 内部切到 actor 的 executor（后台），完成后自动回主线程
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.processingCount -= 1 }

            guard let entry = await process() else { return }

            // 这里已经回到主线程，安全修改 items
            // 新图片总是非置顶，落在"非置顶组"的开头（即所有置顶之后）
            self.insertAtGroupHead(ClipboardItem(kind: .image(entry)))
            self.evictIfNeeded()
            self.scheduleSave()
        }
    }

    // MARK: - 排序

    // 把条目插到所属组的开头：置顶组 = 列表最顶（0），非置顶组 = 所有置顶项之后
    // togglePin / addText / 图片入库 / setMaxPinned 降级共用这一条排序规则
    private func insertAtGroupHead(_ item: ClipboardItem) {
        items.insert(item, at: item.isPinned ? 0 : pinnedCount)
    }

    // MARK: - 容量管理

    // 容量规则（置顶条目不计入限制、不会被 evict）：
    //   1. 非置顶图片数 > maxImages → 删最老的非置顶图片
    //   2. 非置顶总数 > maxItems → 删最末的非置顶条目
    private func evictIfNeeded() {
        // 规则 1：图片数量上限
        while nonPinnedImageCount > maxImages {
            guard let oldestImageIndex = items.lastIndex(where: {
                $0.kind.asImage != nil && !$0.isPinned
            }) else {
                break
            }
            removeItem(at: oldestImageIndex)
        }

        // 规则 2：总数上限
        while nonPinnedCount > maxItems {
            guard let lastNonPinnedIndex = items.lastIndex(where: { !$0.isPinned }) else {
                break
            }
            removeItem(at: lastNonPinnedIndex)
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

    // 当前图片条目数（不分置顶/非置顶，用于加载日志）
    private var imageCount: Int {
        items.lazy.filter { $0.kind.asImage != nil }.count
    }

    // 置顶条目数（用于排序时定位"非置顶组的开头"）
    private var pinnedCount: Int {
        items.lazy.filter { $0.isPinned }.count
    }

    // 非置顶条目数（用于容量判断）
    private var nonPinnedCount: Int {
        items.count - pinnedCount
    }

    // 非置顶图片条目数（用于图片容量判断）
    private var nonPinnedImageCount: Int {
        items.lazy.filter { $0.kind.asImage != nil && !$0.isPinned }.count
    }
}

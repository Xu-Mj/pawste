import Foundation

// 历史持久化层 —— 只管"把 [ClipboardItem] 读写到 JSON 文件"这一件事
//
// 从 PasteboardWatcher 抽出来：watcher 专注领域逻辑（去重/置顶/容量/eviction），
// 这里专注磁盘 I/O（编解码 + 防抖写盘 + 文件路径）。
//
// 防抖：最后一次变更后 1 秒才真写盘，连续复制不会频繁 I/O。
// 每次 scheduleSave 传入当前 items 快照；窗口内再次调用会取消上一次、用新快照重排。
@MainActor
final class HistoryStore {

    // MARK: - 文件位置

    // ~/Library/Application Support/Pawste/（沙盒下在容器内）
    static let appDir: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport.appendingPathComponent("Pawste", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // 原图存放目录（ImageProcessor 用）
    static let imagesDir: URL = appDir.appendingPathComponent("images", isDirectory: true)

    // 历史元数据 JSON（含缩略图 base64）
    private static let storeURL: URL = appDir.appendingPathComponent("history.json")

    private var pendingSaveTask: Task<Void, Never>?

    // MARK: - 读

    // 加载历史；无文件 / 解码失败都返回 []（解码失败会顺手清掉坏文件）
    func load() -> [ClipboardItem] {
        do {
            let data = try Data(contentsOf: Self.storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ClipboardItem].self, from: data)
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            log("📂 首次启动，无历史文件")
            return []
        } catch {
            // 解码失败大概率是旧 schema 不兼容，直接清掉重来（用户已同意此策略）
            log("⚠️ 历史文件解码失败，清空重来: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: Self.storeURL)
            return []
        }
    }

    // MARK: - 写

    // 防抖保存：取消上一次，1 秒后写入这次的快照
    func scheduleSave(_ items: [ClipboardItem]) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow(items)
        }
    }

    // 立即写盘（退出时同步落盘，确保最后的变更不丢）
    func flush(_ items: [ClipboardItem]) {
        pendingSaveTask?.cancel()
        saveNow(items)
    }

    private func saveNow(_ items: [ClipboardItem]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: Self.storeURL, options: .atomic)
        } catch {
            log("⚠️ 保存历史失败: \(error.localizedDescription)")
        }
    }
}

import AppKit          // NSPasteboard 在 AppKit 框架里
import Observation     // @Observable 宏在这里
import Foundation      // FileManager / JSONEncoder

@Observable
final class PasteboardWatcher {

    // MARK: - 状态

    // 剪贴板历史数组。最新的在最前 [0]，最老的在最后
    private(set) var items: [ClipboardItem] = []

    // 历史最大条数。从 UserDefaults 读，没存过就用默认值 100
    // private(set) 让 UI 能读到当前上限（显示在设置界面）
    private(set) var maxItems: Int

    // 上一次看到的 changeCount
    private var lastChangeCount: Int

    // 轮询用 Timer
    private var timer: Timer?

    // 轮询间隔
    private let pollingInterval: TimeInterval = 0.3

    // MARK: - 持久化

    // UserDefaults 里存上限的 key
    private static let maxItemsKey = "maxItems"
    private static let defaultMaxItems = 100

    // 历史 JSON 文件的位置
    // static let + 闭包：第一次访问时计算，结果常驻
    //
    // 路径：~/Library/Application Support/Clip/history.json
    // 这是 macOS App 用户数据的"官方"位置，备份会被 Time Machine 包含
    private static let storeURL: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!  // 用户的 Application Support 一定有，强解包 OK
        let dir = appSupport.appendingPathComponent("Clip", isDirectory: true)
        // try? = "尝试，失败就吞掉"（这里目录已存在会抛错，吞掉无所谓）
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    // 防抖保存：用 Task 实现"最后一次变更后 N 秒才写盘"
    // 避免连续复制时频繁 IO
    private var pendingSaveTask: Task<Void, Never>?

    // MARK: - 生命周期

    init() {
        // 读取容量上限
        let stored = UserDefaults.standard.integer(forKey: Self.maxItemsKey)
        // UserDefaults.integer 取不到 key 时返回 0，我们用 0 当哨兵值表示"没设过"
        self.maxItems = stored > 0 ? stored : Self.defaultMaxItems

        self.lastChangeCount = NSPasteboard.general.changeCount

        // 从磁盘加载历史（所有 stored property 已经初始化，可以调方法了）
        loadFromDisk()
    }

    deinit {
        timer?.invalidate()
        print("🗑️ PasteboardWatcher 已释放")
    }

    // MARK: - 公开 API

    func start() {
        guard timer == nil else {
            print("⚠️ PasteboardWatcher 已经在运行")
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.check()
        }

        print("📋 PasteboardWatcher 启动，轮询间隔 \(Int(pollingInterval * 1000))ms，容量上限 \(maxItems)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        print("⏸️ PasteboardWatcher 已停止")
    }

    func clear() {
        items.removeAll()
        print("🗑️ 历史已清空")
        scheduleSave()
    }

    // 设置容量上限（>0）
    // 立即应用：超出就裁掉最老的
    func setMaxItems(_ n: Int) {
        guard n > 0, n != maxItems else { return }
        self.maxItems = n
        UserDefaults.standard.set(n, forKey: Self.maxItemsKey)

        if items.count > n {
            items = Array(items.prefix(n))
            scheduleSave()
        }
        print("📐 容量上限改为 \(n)")
    }

    // App 退出前的同步保存（不能用防抖，要等真落盘）
    func flushSave() {
        pendingSaveTask?.cancel()
        saveNow()
    }

    // MARK: - 持久化逻辑

    private func loadFromDisk() {
        do {
            let data = try Data(contentsOf: Self.storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([ClipboardItem].self, from: data)
            // 应用当前的容量上限（万一历史比上限多）
            items = Array(decoded.prefix(maxItems))
            print("📂 加载历史 \(items.count) 条 from \(Self.storeURL.path)")
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            // 文件不存在 → 首次启动，正常
            print("📂 首次启动，无历史文件")
        } catch {
            print("⚠️ 加载历史失败: \(error.localizedDescription)")
        }
    }

    // 同步写盘。调用方负责决定时机（防抖触发 or 退出前 flush）
    private func saveNow() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // .prettyPrinted + .sortedKeys：人类可读的格式 + 键排序，diff 友好
            // 对 100 条文本数据，pretty 多耗 2KB 不算什么
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            // .atomic：先写临时文件，写完后原子 rename，断电也不会留半截文件
            try data.write(to: Self.storeURL, options: .atomic)
        } catch {
            print("⚠️ 保存历史失败: \(error.localizedDescription)")
        }
    }

    // 防抖保存：每次调用取消前一次 Task，新 Task 等 1 秒
    // 只有 1 秒内没新调用才真正写盘
    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            // try? + Task.sleep：被 cancel 时 sleep 抛 CancellationError，try? 吞掉
            try? await Task.sleep(for: .seconds(1))
            // 二次检查：cancel 后可能 sleep 还没抛就被恢复
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    // MARK: - 内部逻辑

    private func check() {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount

        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if let text = pasteboard.string(forType: .string) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            addItem(text: text)
        } else {
            print("📋 [\(current)] changeCount 变化，但没有纯文本内容（可能是图片/文件）")
        }
    }

    private func addItem(text: String) {
        if let existingIndex = items.firstIndex(where: { $0.text == text }) {
            let existing = items.remove(at: existingIndex)
            items.insert(existing, at: 0)
            print("🔄 重排已有内容到顶部: \(preview(of: text))")
        } else {
            items.insert(ClipboardItem(text: text), at: 0)
            if items.count > maxItems {
                items.removeLast()
            }
            print("➕ 新内容 (共 \(items.count) 条): \(preview(of: text))")
        }

        // 任何 items 变化都触发防抖保存
        scheduleSave()
    }

    private func preview(of text: String) -> String {
        let cleaned = text.prefix(80).replacingOccurrences(of: "\n", with: "\\n")
        return text.count > 80 ? "\(cleaned)..." : String(cleaned)
    }
}

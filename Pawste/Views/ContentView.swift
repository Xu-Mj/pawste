import SwiftUI
import AppKit

struct ContentView: View {

    let watcher: PasteboardWatcher
    // 共享 UI 状态（list / settings 模式切换 + openCount 开窗信号），由 StatusBarController 注入
    let uiState: PanelUIState
    let onSelect: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    @State private var selectedID: ClipboardItem.ID?
    // 显式滚动触发器：每次置顶切换 +1，让 itemList 知道"滚动到选中"
    // 不能依赖 onChange(of: selectedID)，因为置顶时 selectedID 没变（同一 item 换位置）
    @State private var scrollPing: Int = 0

    // 搜索查询字符串。空字符串 = 不过滤
    @State private var searchQuery: String = ""

    // 搜索框是否获得焦点
    // 用于：1) 区分 1-9 / ⌫ 等快捷键是去搜索框还是去列表
    //       2) Esc 行为分支（已聚焦清查询 / 失焦 → 关 popup）
    @FocusState private var searchFocused: Bool

    // MARK: - 过滤

    // 子串匹配（不区分大小写），同时支持文本和图片 displayName
    // 空查询直接返回原 items，避免无谓的 filter 调用
    private func filter(_ items: [ClipboardItem]) -> [ClipboardItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { item in
            switch item.kind {
            case .text(let s):
                return s.lowercased().contains(q)
            case .image(let entry):
                return entry.displayName.lowercased().contains(q)
            }
        }
    }

    private var filteredPinned: [ClipboardItem] { filter(watcher.pinnedItems) }
    private var filteredUnpinned: [ClipboardItem] { filter(watcher.unpinnedItems) }

    // 当前是否处于"搜索激活"状态（用于决定空状态文案、底栏提示等）
    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        keyboardRouting(glassContainer)
    }

    // 玻璃容器：按模式分发内容 + 统一玻璃/配色/可聚焦
    // 外层玻璃统一管理，切换模式时玻璃不闪烁，焦点、键盘事件都在同一 view tree
    private var glassContainer: some View {
        Group {
            switch uiState.mode {
            case .list:
                listMode
            case .settings:
                SettingsView(
                    watcher: watcher,
                    onBack: { uiState.mode = .list }
                )
            case .about:
                AboutView(
                    onBack: { uiState.mode = .list }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(
            .clear.tint(.black.opacity(0.95)),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .preferredColorScheme(.dark)
        // .focusable 必须在 .onKeyPress 之前，否则收不到键盘事件
        .focusable()
        .focusEffectDisabled()
    }

    // MARK: - 键盘路由

    // 全部键盘事件 + 瞬时状态重置，从 body 抽出避免过长
    // 各 .onKeyPress 都 guard uiState.mode == .list（.settings/.about 自己处理 Esc）
    private func keyboardRouting(_ content: some View) -> some View {
        content
        .onKeyPress(.upArrow) {
            guard uiState.mode == .list else { return .ignored }
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard uiState.mode == .list else { return .ignored }
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            guard uiState.mode == .list else { return .ignored }
            triggerSelected()
            return .handled
        }
        // Delete 键：删除选中条目
        // 搜索框聚焦时 ⌫ 是删字符，让给 TextField，不做条目删除
        //
        // 关键陷阱：SwiftUI 的 KeyEquivalent.delete 实际是 \u{7F} (forward delete)
        // 而 Mac 上日常 ⌫ 键发的是 \u{08} (BS, backspace 风格)
        // 用 character set 同时匹配两种字符，覆盖所有"删除"键场景
        .onKeyPress(characters: CharacterSet(charactersIn: "\u{08}\u{7F}")) { _ in
            guard uiState.mode == .list, !searchFocused else { return .ignored }
            deleteSelected()
            return .handled
        }
        // ⌘P：切换选中条目的置顶状态
        //
        // SwiftUI .onKeyPress(_: KeyEquivalent) 的 action 闭包不带参数，没法检查 modifiers
        // 必须用 characters: 这个 overload，它会传 KeyPress 进来，能拿 modifiers
        .onKeyPress(characters: CharacterSet(charactersIn: "pP")) { press in
            guard uiState.mode == .list else { return .ignored }
            guard press.modifiers.contains(.command) else { return .ignored }
            togglePinSelected()
            return .handled
        }
        // ⌘F：聚焦搜索框（macOS 标准 Find 快捷键）
        .onKeyPress(characters: CharacterSet(charactersIn: "fF")) { press in
            guard uiState.mode == .list else { return .ignored }
            guard press.modifiers.contains(.command) else { return .ignored }
            searchFocused = true
            return .handled
        }
        .onKeyPress(.escape) {
            // 非 list 模式（settings / about）：切回 list
            if uiState.mode != .list {
                uiState.mode = .list
                return .handled
            }
            // 搜索框聚焦中：先解搜索（非空 → 清；空 → 失焦）
            // 注意：这条 outer handler 在 TextField 没消费 Esc 时才触发；
            // 但稳妥起见我们在这里也兜底一次
            if searchFocused {
                if searchQuery.isEmpty {
                    searchFocused = false
                } else {
                    searchQuery = ""
                }
                return .handled
            }
            // 普通 list 状态：关闭 popup
            onDismiss()
            return .handled
        }
        // 1-9（无修饰）：粘贴 filteredUnpinned[N-1]；搜索框聚焦时让数字进框
        // ⌘1-9：粘贴 pinned[N-1]（不受 filtered 影响，永远走全量 pinnedItems）
        //   ── 这是约定：⌘ 修饰一定指向"置顶项"，符合直觉
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789")) { press in
            guard uiState.mode == .list else { return .ignored }
            guard let firstChar = press.characters.first,
                  let digit = firstChar.wholeNumberValue,
                  (1...9).contains(digit) else {
                return .ignored
            }

            if press.modifiers.contains(.command) {
                let pinned = watcher.pinnedItems
                guard digit - 1 < pinned.count else { return .ignored }
                onSelect(pinned[digit - 1])
                return .handled
            }

            // 无修饰：搜索框聚焦时让 TextField 收数字
            guard !searchFocused else { return .ignored }
            let filtered = filteredUnpinned
            guard digit - 1 < filtered.count else { return .ignored }
            onSelect(filtered[digit - 1])
            return .handled
        }
        // 每次重新打开 popup 都重置搜索 + 选中
        // 用 openCount 而非 .onAppear，因为 SwiftUI view tree 常驻不会重新 appear
        .onChange(of: uiState.openCount) { _, _ in
            resetEphemeralState()
        }
        // 搜索查询变化时：选中跳回过滤结果的第一条
        // 否则上一次的 selectedID 可能已经被过滤掉，看起来"没选中"
        .onChange(of: searchQuery) { _, _ in
            selectedID = filteredUnpinned.first?.id
        }
        .onAppear {
            Task { @MainActor in
                selectedID = watcher.unpinnedItems.first?.id
            }
        }
    }

    // 剪贴板列表模式的整体布局
    private var listMode: some View {
        VStack(spacing: 0) {
            header
            pinnedSection
            content
            footer
        }
    }

    // 置顶区：水平滚动的 chip 行
    // 搜索时也跟随过滤 —— 搜索意图是"在所有内容里找"，不该把置顶项排除在外
    // chip 宽度由 PinnedChip 自管理：文本 100、图片 32（正方形）
    @ViewBuilder
    private var pinnedSection: some View {
        let pinned = filteredPinned
        if !pinned.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(pinned.enumerated()), id: \.element.id) { index, item in
                        PinnedChip(
                            item: item,
                            index: index,
                            onTap: { onSelect(item) },
                            onUnpin: { watcher.togglePin(id: item.id) }
                        )
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.bottom, 6)
        }
    }

    // MARK: - Header（搜索框 + 齿轮 + 垃圾桶）

    private var header: some View {
        HStack(spacing: 8) {
            searchField
            settingsButton
            clearButton
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // 搜索框：放大镜图标 + TextField + 清除 × 按钮（仅在有内容时显示）
    private var searchField: some View {
        HStack(spacing: 6) {
            // 用固定白色不透明度，不用 .secondary
            // Liquid Glass 的 vibrancy 会拿浮窗背后内容做混合，把层级色冲淡到几乎看不见
            // （真实显示时淡、截图反而清楚就是这个原因）；显式颜色不走 vibrancy，渲染稳定
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))

            TextField("搜索", text: $searchQuery,
                      prompt: Text("搜索").foregroundColor(.white.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .onSubmit { triggerSelected() }
                // 局部 Esc 处理：把"清查询 / 失焦"留在框内消费，不冒到外层关 popup
                .onKeyPress(.escape) {
                    if searchQuery.isEmpty {
                        searchFocused = false
                    } else {
                        searchQuery = ""
                    }
                    return .handled
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("清除搜索")
                .pointerCursor()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(searchFocused ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(searchFocused ? 0.18 : 0), lineWidth: 0.5)
        )
    }

    private var settingsButton: some View {
        // 偏好设置入口（齿轮）
        // 不再通过右键菜单进入 settings，因为 NSMenu action → 新 panel 的过渡会让 panel 进入半 key 状态
        // 直接在 popup 里切模式则没有任何窗口/key 状态变化，所有事件路由保持稳定
        Button {
            uiState.mode = .settings
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
        }
        .buttonStyle(.borderless)
        .help("偏好设置")
        .pointerCursor()
    }

    private var clearButton: some View {
        Button {
            watcher.clear()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
        }
        .buttonStyle(.borderless)
        .disabled(watcher.items.isEmpty)
        .help("清空历史")
        .pointerCursor()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if watcher.items.isEmpty && !watcher.isProcessingImage {
            // 库本身为空
            emptyState
        } else if filteredUnpinned.isEmpty && filteredPinned.isEmpty && isSearching {
            // 库有内容但当前过滤无匹配
            noMatchState
        } else {
            itemList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.glassTertiary)
            Text("还没有剪贴板历史")
                .font(.system(size: 13))
                .foregroundStyle(.glassSecondary)
            Text("复制点东西试试")
                .font(.system(size: 11))
                .foregroundStyle(.glassTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var noMatchState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.glassTertiary)
            Text("没有匹配「\(searchQuery)」")
                .font(.system(size: 12))
                .foregroundStyle(.glassSecondary)
            Text("Esc 清除搜索")
                .font(.system(size: 10))
                .foregroundStyle(.glassTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    // Loading 占位条：处理图片时出现在顶部
                    // 搜索激活时不显示（处理中的条目还没归档，不参与过滤）
                    if watcher.isProcessingImage && !isSearching {
                        ProcessingRow()
                    }

                    // 列表区只显示非置顶项（置顶项在 pinnedSection 单独渲染）
                    ForEach(Array(filteredUnpinned.enumerated()), id: \.element.id) { index, item in
                        ItemRow(
                            item: item,
                            index: index,
                            isSelected: item.id == selectedID,
                            onTap: { onSelect(item) },
                            onPinToggle: { watcher.togglePin(id: item.id) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.vertical, 4)
            }
            // 键盘 ↑↓ 导航：直接同步 snap，不用 Task wrap、不用动画
            //
            // 之前的写法（Task @MainActor + withAnimation 0.12s）在长按方向键时会出 bug：
            //   - 30Hz 重复事件 → 短时间内堆积大量 Task
            //   - 每个 Task 里 withAnimation 触发一次 LazyVStack 滚动动画
            //   - 接近列表末尾时 LazyVStack 还要实例化尚未渲染的 ItemRow（图片要 NSImage(data:) 解码）
            //   - 主线程被解码 + 动画排队吃满 → 彩虹鼠标，选中停在某个位置
            // 改成同步直调 scrollTo 后没有任务堆积，键盘导航也不需要动画（要的是即时反馈）
            .onChange(of: selectedID) { _, newID in
                guard let id = newID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            // 显式滚动触发器（用于置顶后 selectedID 没变但位置变了的场景）
            // 这是单次用户事件（⌘P / 点 pin 图标），不会高频触发，保留动画无副作用
            .onChange(of: scrollPing) { _, _ in
                guard let id = selectedID else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Footer

    // 间距 4：HStack 在 360 宽 popup 里偏紧；所有 Text 加 .fixedSize 禁止 SwiftUI 自动换行
    // 计数显示过滤后数量；带搜索时多展示一行"已过滤"指示
    private var footer: some View {
        HStack(spacing: 4) {
            Text("\(filteredUnpinned.count) 条")
                .fixedSize(horizontal: true, vertical: false)
            Text("·")
            Text("1-9 粘贴")
                .fixedSize(horizontal: true, vertical: false)
            Text("·")
            Text("⌘1-5 置顶")
                .fixedSize(horizontal: true, vertical: false)
            Text("·")
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 9))
            Text("选择")
                .fixedSize(horizontal: true, vertical: false)
            Text("·")
            Image(systemName: "delete.left")
                .font(.system(size: 9))
            Text("删除")
                .fixedSize(horizontal: true, vertical: false)
            Text("·")
            Text("⌘F 搜索")
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.plain)
            .foregroundStyle(.glassSecondary)
            .pointerCursor()
        }
        .font(.system(size: 10))
        .foregroundStyle(.glassTertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 选择逻辑（都基于 filteredUnpinned）

    private func moveSelection(by delta: Int) {
        let items = filteredUnpinned
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        let newIndex = max(0, min(items.count - 1, currentIndex + delta))
        selectedID = items[newIndex].id
    }

    private func triggerSelected() {
        guard let id = selectedID,
              let item = watcher.items.first(where: { $0.id == id }) else { return }
        onSelect(item)
    }

    // 切换选中条目的置顶状态（键盘 ⌘P 路径）
    // watcher.togglePin 内部已有上限检查，超限时会 print warning 并返回 false（静默）
    private func togglePinSelected() {
        guard let id = selectedID else { return }
        watcher.togglePin(id: id)
        scrollPing += 1
    }

    // 删除当前选中条目，并把选中转移到下一条
    //
    // 选中转移策略（参考 Mail、Finder 等系统 App）：
    //   - 删的不是末位 → 选中原 index（自然变成原来的下一条）
    //   - 删的是末位 → 选中新的末位（向上移一位）
    //   - 删后空了 → selectedID = nil
    //
    // 在 filtered 视图下做相对位置，避免搜索时删除跳到全局其他位置
    private func deleteSelected() {
        guard let id = selectedID else { return }
        guard let oldIndex = filteredUnpinned.firstIndex(where: { $0.id == id }) else { return }

        watcher.deleteItem(id: id)

        // 删完后 filteredUnpinned 计算属性会重新求值
        let newItems = filteredUnpinned
        if newItems.isEmpty {
            selectedID = nil
        } else {
            let newIndex = min(oldIndex, newItems.count - 1)
            selectedID = newItems[newIndex].id
        }
    }

    // 每次重新打开 popup 时调用：清搜索 + 复位选中
    // 保持"开窗即新鲜状态"，不让上一次的搜索/选中影响这次
    private func resetEphemeralState() {
        searchQuery = ""
        searchFocused = false
        selectedID = watcher.unpinnedItems.first?.id
    }
}

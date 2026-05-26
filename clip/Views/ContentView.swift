import SwiftUI
import AppKit

struct ContentView: View {

    let watcher: PasteboardWatcher
    // 共享 UI 状态（list / settings 模式切换），由 StatusBarController 注入
    let uiState: PanelUIState
    let onSelect: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    @State private var selectedID: ClipboardItem.ID?
    // 显式滚动触发器：每次置顶切换 +1，让 itemList 知道"滚动到选中"
    // 不能依赖 onChange(of: selectedID)，因为置顶时 selectedID 没变（同一 item 换位置）
    @State private var scrollPing: Int = 0

    var body: some View {
        // 根据模式分发不同的内容视图，外层玻璃容器统一管理
        // 这样切换模式时玻璃不闪烁，焦点、键盘事件等也都在同一个 view tree 里
        Group {
            switch uiState.mode {
            case .list:
                listMode
            case .settings:
                SettingsView(
                    watcher: watcher,
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
        // 键盘事件 + onAppear 只在 .list 模式生效
        // .settings 模式有自己的 Esc 处理（在 SettingsView 里）
        .focusable()
        .focusEffectDisabled()
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
        //
        // 关键陷阱：SwiftUI 的 KeyEquivalent.delete 实际是 \u{7F} (forward delete)
        // 而 Mac 上日常 ⌫ 键发的是 \u{08} (BS, backspace 风格)
        // 用 character set 同时匹配两种字符，覆盖所有"删除"键场景
        //
        // 删除后选中智能转移：尽量保持位置不变（即原 index 的下一条），列表为空则 nil
        .onKeyPress(characters: CharacterSet(charactersIn: "\u{08}\u{7F}")) { _ in
            guard uiState.mode == .list else { return .ignored }
            deleteSelected()
            return .handled
        }
        // ⌘P：切换选中条目的置顶状态
        //
        // SwiftUI .onKeyPress(_: KeyEquivalent) 的 action 闭包不带参数，没法检查 modifiers
        // 必须用 characters: 这个 overload，它会传 KeyPress 进来，能拿 modifiers
        // 这也和上面的数字键处理保持一致
        .onKeyPress(characters: CharacterSet(charactersIn: "pP")) { press in
            guard uiState.mode == .list else { return .ignored }
            guard press.modifiers.contains(.command) else { return .ignored }
            togglePinSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            // .settings 模式下 Esc 切回 list（不关 popup）
            // .list 模式下 Esc 关 popup
            if uiState.mode == .settings {
                uiState.mode = .list
            } else {
                onDismiss()
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789")) { press in
            guard uiState.mode == .list else { return .ignored }
            guard let firstChar = press.characters.first,
                  let digit = firstChar.wholeNumberValue,
                  (1...9).contains(digit) else {
                return .ignored
            }

            // ⌘1-5 → 触发置顶项；不带 ⌘ 的 1-9 → 触发列表项
            if press.modifiers.contains(.command) {
                let pinned = watcher.pinnedItems
                guard digit - 1 < pinned.count else { return .ignored }
                onSelect(pinned[digit - 1])
            } else {
                let unpinned = watcher.unpinnedItems
                guard digit - 1 < unpinned.count else { return .ignored }
                onSelect(unpinned[digit - 1])
            }
            return .handled
        }
        .onAppear {
            Task { @MainActor in
                // 默认选中第一个非置顶项（置顶不参与键盘导航）
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
    // 0 条置顶时折叠不显示
    // chip 宽度由 PinnedChip 自管理：文本 100、图片 32（正方形）
    // 多余的横向滚动查看（鼠标拖动滚动条 / trackpad 横向手势）
    @ViewBuilder
    private var pinnedSection: some View {
        let pinned = watcher.pinnedItems
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("剪贴板")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            // 偏好设置入口（齿轮）
            // 不再通过右键菜单进入 settings，因为 NSMenu action → 新 panel 的过渡会让 panel 进入半 key 状态
            // 直接在 popup 里切模式则没有任何窗口/key 状态变化，所有事件路由保持稳定
            Button {
                uiState.mode = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("偏好设置")
            .pointerCursor()

            Button {
                watcher.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(watcher.items.isEmpty)
            .help("清空历史")
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if watcher.items.isEmpty && !watcher.isProcessingImage {
            emptyState
        } else {
            itemList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有剪贴板历史")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("复制点东西试试")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    // Loading 占位条：处理图片时出现在顶部
                    if watcher.isProcessingImage {
                        ProcessingRow()
                    }

                    // 列表区只显示非置顶项（置顶项在 pinnedSection 单独渲染）
                    ForEach(Array(watcher.unpinnedItems.enumerated()), id: \.element.id) { index, item in
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
            .onChange(of: selectedID) { _, newID in
                guard let id = newID else { return }
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            // 显式滚动触发器（用于置顶后 selectedID 没变但位置变了的场景）
            .onChange(of: scrollPing) { _, _ in
                guard let id = selectedID else { return }
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    // 间距 4（之前 6）：HStack 在 360 宽 popup 里偏紧，缩 2pt 让 13 个子元素能塞下
    // 每个 Text 都加 .fixedSize 禁止 SwiftUI 自动换行
    //   ── 之前 "1-9 粘贴" / "⌘1-5 置顶" 含空格被自动拆两行，破坏风格统一
    private var footer: some View {
        HStack(spacing: 4) {
            Text("\(watcher.unpinnedItems.count) 条")
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
            Text("⌘P 置顶")
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .pointerCursor()
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 选择逻辑

    private func moveSelection(by delta: Int) {
        // 键盘导航只在非置顶列表里走
        let items = watcher.unpinnedItems
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
    // 用户调高上限可在偏好设置里
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
    private func deleteSelected() {
        guard let id = selectedID else { return }
        // 在"非置顶列表"里找位置（置顶不参与键盘选中，也不会被这条路径删）
        guard let oldIndex = watcher.unpinnedItems.firstIndex(where: { $0.id == id }) else { return }

        watcher.deleteItem(id: id)

        // 删完后重新拿非置顶列表，决定新的 selectedID
        let newItems = watcher.unpinnedItems
        if newItems.isEmpty {
            selectedID = nil
        } else {
            let newIndex = min(oldIndex, newItems.count - 1)
            selectedID = newItems[newIndex].id
        }
    }
}

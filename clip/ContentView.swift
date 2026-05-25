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
                  (1...9).contains(digit),
                  digit - 1 < watcher.items.count else {
                return .ignored
            }
            onSelect(watcher.items[digit - 1])
            return .handled
        }
        .onAppear {
            Task { @MainActor in
                selectedID = watcher.items.first?.id
            }
        }
    }

    // 剪贴板列表模式的整体布局
    private var listMode: some View {
        VStack(spacing: 0) {
            header
            content
            footer
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

                    ForEach(Array(watcher.items.enumerated()), id: \.element.id) { index, item in
                        ItemRow(
                            item: item,
                            index: index,
                            isSelected: item.id == selectedID,
                            onTap: { onSelect(item) },
                            // 鼠标点置顶图标：直接 toggle，不动 selection、不触发滚动
                            // 用户能看到点的是哪一个，没必要再滚或选
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

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(watcher.items.count) 条")
            Text("·")
            Text("1-9 粘贴")
            Text("·")
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 9))
            Text("选择")
            Text("·")
            Image(systemName: "return")
                .font(.system(size: 9))
            Text("粘贴")
            Text("·")
            Image(systemName: "delete.left")
                .font(.system(size: 9))
            Text("删除")
            Text("·")
            Image(systemName: "pin")
                .font(.system(size: 9))
            Text("⌘P 置顶")
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 选择逻辑

    private func moveSelection(by delta: Int) {
        let items = watcher.items
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
    // selectedID 不变（同一 item），但位置变了，所以单独 ping 一下让列表滚动到它
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
        guard let oldIndex = watcher.items.firstIndex(where: { $0.id == id }) else { return }

        watcher.deleteItem(id: id)

        // 删完后 watcher.items 已经少一项，决定新的 selectedID
        let newItems = watcher.items
        if newItems.isEmpty {
            selectedID = nil
        } else {
            // 原 index 在新数组里的同位置就是"下一条"；如果超出末位则取末位
            let newIndex = min(oldIndex, newItems.count - 1)
            selectedID = newItems[newIndex].id
        }
    }
}

// MARK: - 单行视图

private struct ItemRow: View {

    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let onTap: () -> Void
    let onPinToggle: () -> Void  // 鼠标点 pin 图标时触发

    @State private var isHovered = false

    private var hasShortcut: Bool { index < 9 }

    var body: some View {
        // 整体改用 onTapGesture 而不是 Button：
        // 原因：要在行内嵌一个独立可点击的 pin Button
        // SwiftUI 里 Button 套 Button 点击事件会冲突
        // 改成"外层 onTapGesture + 内层 Button"，Button 的点击区域优先于 onTapGesture，互不干扰
        HStack(spacing: 10) {
            shortcutBadge

            switch item.kind {
            case .text(let text):
                textContent(text)
            case .image(let entry):
                imageContent(entry)
            }

            Spacer(minLength: 4)

            pinButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundFill)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .onHover { isHovered = $0 }
    }

    // 置顶图标按钮
    //
    // 显示规则：
    //   - 置顶项：常驻显示填充版 pin.fill（让用户一眼看到置顶状态，点击取消）
    //   - 非置顶项：只在 hover 时显示空心 pin（暗示"可以点这里置顶"）
    @ViewBuilder
    private var pinButton: some View {
        if item.isPinned {
            // 置顶项：常驻填充图标，点击取消置顶
            Button {
                onPinToggle()
            } label: {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(pinColor)
                    // 固定宽度，防止显示/隐藏时其他内容跳动
                    .frame(width: 14, alignment: .center)
            }
            .buttonStyle(.plain)
            .help("取消置顶 (⌘P)")
        } else if isHovered {
            // 非置顶 + hover：显示空心图标，点击置顶
            Button {
                onPinToggle()
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(pinColor)
                    .frame(width: 14, alignment: .center)
            }
            .buttonStyle(.plain)
            .help("置顶 (⌘P)")
        } else {
            // 非置顶 + 没 hover：占位空 view，保持其他内容布局稳定
            Color.clear.frame(width: 14, height: 14)
        }
    }

    // MARK: - 子视图

    private var shortcutBadge: some View {
        Text(hasShortcut ? "\(index + 1)" : "")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(numberColor)
            .frame(width: 14, alignment: .center)
    }

    private func textContent(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .white : .primary)

            Text(item.copiedAt.relativeShort)
                .font(.system(size: 10))
                .foregroundStyle(timeColor)
        }
    }

    @ViewBuilder
    private func imageContent(_ entry: ClipboardItem.ImageEntry) -> some View {
        // 缩略图
        Group {
            if let nsImage = NSImage(data: entry.thumbnail) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
            } else {
                // 缩略图 Data 损坏时的兜底
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .background(Color.black.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))

        VStack(alignment: .leading, spacing: 1) {
            Text(entry.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .white : .primary)

            HStack(spacing: 4) {
                Text("\(entry.width)×\(entry.height)")
                Text("·")
                Text(item.copiedAt.relativeShort)
            }
            .font(.system(size: 10))
            .foregroundStyle(timeColor)
        }
    }

    // MARK: - 颜色

    private var numberColor: Color {
        isSelected ? Color.white.opacity(0.9) : Color.primary.opacity(0.35)
    }

    private var timeColor: Color {
        isSelected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.85)
    }

    private var pinColor: Color {
        isSelected ? Color.white.opacity(0.85) : Color.secondary
    }

    private var backgroundFill: Color {
        if isSelected { return .accentColor }
        if isHovered { return .accentColor.opacity(0.12) }
        return .clear
    }
}

// MARK: - 处理中占位条

private struct ProcessingRow: View {
    var body: some View {
        HStack(spacing: 10) {
            // 序号位置：小 spinner
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, alignment: .center)

            // 缩略图占位
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.08))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text("处理图片中…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("稍候片刻")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04))
                .padding(.horizontal, 4)
        )
    }
}

// MARK: - Date 扩展

extension Date {
    var relativeShort: String {
        let interval = Date().timeIntervalSince(self)
        switch interval {
        case ..<60:
            return "刚刚"
        case ..<3600:
            return "\(Int(interval / 60)) 分钟前"
        case ..<86400:
            return "\(Int(interval / 3600)) 小时前"
        case ..<(86400 * 7):
            return "\(Int(interval / 86400)) 天前"
        default:
            let f = DateFormatter()
            f.dateFormat = "MM-dd"
            return f.string(from: self)
        }
    }
}

import SwiftUI
import AppKit

struct ContentView: View {

    let watcher: PasteboardWatcher
    // 选中一条历史时的回调。改为传 ClipboardItem 而非 String，
    // 因为图片场景 StatusBarController 需要 filename / displayName 等元数据
    let onSelect: (ClipboardItem) -> Void
    let onDismiss: () -> Void

    @State private var selectedID: ClipboardItem.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // macOS 26 Liquid Glass —— 和 Spotlight / 通知中心同款渲染管线
        //
        // 已知问题：会触发一次 `_NSDetectedLayoutRecursion` warning（启动时打印一次）
        // 经实验确认这是 SwiftUI 真模糊渲染管线 + NSHostingController 的 Apple bug
        // 不只 .glassEffect()，所有"真模糊"路径都会触发：
        //   - .glassEffect()
        //   - .background(.ultraThinMaterial / .regularMaterial / ...)
        //   - NSVisualEffectView
        // 唯一不触发的是纯色背景，但视觉不可接受
        // 这条 warning 只打印一次、不影响功能、是 Apple 自家 bug
        //
        // tint opacity 0.25 = 偏透；0.35 = 中等；0.45 = 偏深；0.55+ = 接近不透
        .glassEffect(
            .clear.tint(.black.opacity(0.95)),
            in: RoundedRectangle(cornerRadius: 14)
        )
        // 强制 panel 内部走 dark color scheme（不管系统主题）
        // Spotlight 在亮色模式下也是这样：内容区永远是暗色调，文字才有保证
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            triggerSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "123456789")) { press in
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text("剪贴板")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

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
                            onTap: { onSelect(item) }
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
}

// MARK: - 单行视图

private struct ItemRow: View {

    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    private var hasShortcut: Bool { index < 9 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                shortcutBadge
                // switch over Kind 决定渲染样式
                // @ViewBuilder 接受 switch，分支返回不同 View 类型也 OK
                switch item.kind {
                case .text(let text):
                    textContent(text)
                case .image(let entry):
                    imageContent(entry)
                }
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
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
        case ..<5:
            return "刚刚"
        case ..<60:
            return "\(Int(interval)) 秒前"
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

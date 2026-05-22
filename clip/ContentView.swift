import SwiftUI
import AppKit

struct ContentView: View {

    let watcher: PasteboardWatcher
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    @State private var selectedID: ClipboardItem.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        // 让 VStack 填满整个 panel（NSHostingView 的 frame 决定外尺寸）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // macOS 26 的 Liquid Glass：和 Spotlight / 通知中心同款渲染管线
        //
        // 用 .clear 才能保留真正的液态玻璃质感
        // .regular 配上 tint 之后磨砂底色叠加，反而像纯色块——透明感消失
        // .clear 本身极透 → 配 0.35 黑色 tint 把对比度提到可读，同时保留玻璃感
        //
        // 参数调节：
        //   tint opacity 0.25 = 偏透；0.35 = 中等可读；0.45 = 偏深可读；0.55+ = 接近不透
        .glassEffect(
            .clear.tint(.black.opacity(0.55)),
            in: RoundedRectangle(cornerRadius: 14)
        )
        // 强制 panel 内部走 dark color scheme（不管系统主题）
        // Spotlight 在亮色模式下也是这样：内容区永远是暗色调，文字才有保证
        // .primary 在 dark 下自动变白色系，.secondary 变浅灰，对比度直接合格
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
            onSelect(watcher.items[digit - 1].text)
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
                // 比 .headline 略小一点，更精致
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            // 清空按钮：尺寸更小、颜色更柔和
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

    // MARK: - Content (list or empty)

    @ViewBuilder
    private var content: some View {
        if watcher.items.isEmpty {
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
                // 列表上下留 4pt，让首末项不贴着 header/footer
                LazyVStack(spacing: 1) {
                    ForEach(Array(watcher.items.enumerated()), id: \.element.id) { index, item in
                        ItemRow(
                            item: item,
                            index: index,
                            isSelected: item.id == selectedID,
                            onTap: { onSelect(item.text) }
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
            // 用 SF Symbols 表达快捷键，比纯文字更精致
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
        onSelect(item.text)
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
                // 序号：monospaced + medium，前 9 条显示，10+ 留空保持对齐
                Text(hasShortcut ? "\(index + 1)" : "")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(numberColor)
                    .frame(width: 14, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? .white : .primary)

                    // 用我们自己的时间格式（"5 分钟前" 这种），比 SwiftUI 默认 "7 min, 9 sec" 干净
                    Text(item.copiedAt.relativeShort)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // 关键：选中/hover 背景是"圆角块、左右内缩 4pt"，不再整行实色
            // Spotlight 风的核心视觉之一
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

    private var numberColor: Color {
        if isSelected { return Color.white.opacity(0.9) }
        return Color.primary.opacity(0.35)
    }

    // 注意：返回 Color 不返回 ShapeStyle，方便 RoundedRectangle.fill() 接受
    private var backgroundFill: Color {
        if isSelected {
            return .accentColor
        }
        if isHovered {
            return .accentColor.opacity(0.12)
        }
        return .clear
    }
}

// MARK: - Date 扩展：中文化的相对时间

extension Date {
    // 把"几秒/分钟/小时/天前"压缩成简短中文格式
    // SwiftUI 内置的 Text(date, style: .relative) 输出 "7 min, 9 sec" 这种，又长又洋
    // 我们自己写一个轻量替代
    //
    // 注意：这是同步快照，不会自动随时间更新
    // 我们的浮窗每次重新打开会重新计算，对剪贴板工具来说足够了
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

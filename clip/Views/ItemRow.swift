import SwiftUI
import AppKit

// 列表中的单行视图（文本 / 图片两种 kind 分别渲染）
//
// 整体改用 onTapGesture 而不是 Button：
// 原因：要在行内嵌一个独立可点击的 pin Button
// SwiftUI 里 Button 套 Button 点击事件会冲突
// 改成"外层 onTapGesture + 内层 Button"，Button 的点击区域优先于 onTapGesture，互不干扰
struct ItemRow: View {

    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let onTap: () -> Void
    let onPinToggle: () -> Void  // 鼠标点 pin 图标时触发

    @State private var isHovered = false

    private var hasShortcut: Bool { index < 9 }

    var body: some View {
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
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .background(Color.black.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))

        // 不再显示 displayName（自动生成的 "Screenshot_xxx.png" 没阅读价值）
        // 第一行展示尺寸，第二行展示时间，结构和文本行保持一致
        VStack(alignment: .leading, spacing: 1) {
            Text("\(entry.width) × \(entry.height)")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .white : .primary)

            Text(item.copiedAt.relativeShort)
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

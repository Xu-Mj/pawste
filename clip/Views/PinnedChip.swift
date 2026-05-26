import SwiftUI
import AppKit

// 置顶条目的紧凑卡片视图
//
// 显示在 popup 顶部置顶区，水平滚动排列，固定宽度
//
// 文本类：⌘N 徽章 + 截断文字
// 图片类：⌘N 徽章 + 缩略图（不显示文件名）
struct PinnedChip: View {

    let item: ClipboardItem
    let index: Int       // 在置顶组里的位置 (0-based)，0-8 对应 ⌘1-⌘9 快捷键
    let onTap: () -> Void
    let onUnpin: () -> Void

    @State private var isHovered = false

    // 前 9 个位置有 ⌘N 快捷键（⌘1-⌘9），更后面的没快捷键就不显示徽章
    private var hasShortcut: Bool { index < 9 }

    var body: some View {
        chipContent
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                // hover 时右上角显示 × 取消置顶
                if isHovered {
                    Button {
                        onUnpin()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white, Color.black.opacity(0.6))
                            .symbolRenderingMode(.palette)
                    }
                    .buttonStyle(.plain)
                    .help("取消置顶")
                    .offset(x: 4, y: -4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var chipContent: some View {
        HStack(spacing: 6) {
            // ⌘N 徽章
            //
            // 风格和 ItemRow 的数字徽章一致：monospaced + medium
            // 加 ⌘ 前缀提示快捷键，区分于列表的数字键
            if hasShortcut {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)  // 防止文字超长时把徽章挤掉
            }

            // 主内容
            switch item.kind {
            case .text(let t):
                Text(t.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

            case .image(let entry):
                if let nsImage = NSImage(data: entry.thumbnail) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .frame(maxWidth: .infinity)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var backgroundFill: Color {
        if isHovered { return Color.accentColor.opacity(0.2) }
        return Color.white.opacity(0.06)
    }
}

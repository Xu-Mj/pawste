import SwiftUI
import AppKit

// 置顶条目的紧凑视图
//
// 统一尺寸 100×32，⌘N 角标统一放右下角（黑底胶囊 + 7pt 白字）
//
// 文本 chip：文字左对齐铺满，右侧 padding 让出 badge 空间
// 图片 chip：缩略图 .scaledToFill 填满整个 chip，居中裁剪
//
// 两种 kind 共用同一布局骨架（外层 frame + bg + overlay 全部相同），
// 只 body 部分按 kind 分别渲染，风格保持一致
struct PinnedChip: View {

    let item: ClipboardItem
    let index: Int       // 在置顶组里的位置 (0-based)，0-8 对应 ⌘1-⌘9 快捷键
    let onTap: () -> Void
    let onUnpin: () -> Void

    @State private var isHovered = false

    // 前 9 个位置有 ⌘N 快捷键（⌘1-⌘9），更后面的没快捷键就不显示徽章
    private var hasShortcut: Bool { index < 9 }

    private let chipWidth: CGFloat = 100
    private let chipHeight: CGFloat = 32

    var body: some View {
        Group {
            switch item.kind {
            case .text(let s):
                textBody(s)
            case .image(let entry):
                imageBody(entry)
            }
        }
        .frame(width: chipWidth, height: chipHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
        )
        .overlay {
            // hover 高亮 + 边框
            // 图片 chip 没有可见背景色（被缩略图盖住），靠这层 hover 提示
            ZStack {
                if isHovered {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.12))
                }
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
        }
        // ⌘N 角标：两种 kind 都固定右下角，视觉风格统一
        .overlay(alignment: .bottomTrailing) {
            if hasShortcut {
                shortcutBadge
                    .padding(3)
            }
        }
        // hover 时显示取消置顶按钮，放右上角内部（不外飘）
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button {
                    onUnpin()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white, Color.black.opacity(0.7))
                        .symbolRenderingMode(.palette)
                }
                .buttonStyle(.plain)
                .help("取消置顶")
                .padding(2)
                .pointerCursor()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .onHover { isHovered = $0 }
        .pointerCursor()
    }

    // MARK: - 统一的右下角 ⌘N 角标

    private var shortcutBadge: some View {
        Text("⌘\(index + 1)")
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(Color.black.opacity(0.65))
            )
    }

    // MARK: - 文本 chip

    // 文字左对齐铺满；右侧 padding 留出 badge 区域避免重叠
    //
    // 显示压成单行预览：内部换行 → ↵ 可见符号（不是空格）
    // 原始内容（item.kind 里的 String）不动，粘贴时还是完整文本
    private func textBody(_ text: String) -> some View {
        Text(text.displayPreview)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.glassPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            // 有 badge 时给右侧留 22pt 让出位置（badge ~14pt + padding 3pt + 安全间距）
            .padding(.trailing, hasShortcut ? 22 : 8)
    }

    // MARK: - 图片 chip：缩略图 .scaledToFill 填满整个 chip

    @ViewBuilder
    private func imageBody(_ entry: ClipboardItem.ImageEntry) -> some View {
        if let nsImage = NSImage(data: entry.thumbnail) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
                .frame(width: chipWidth, height: chipHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.2))
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(.glassSecondary)
                )
        }
    }
}

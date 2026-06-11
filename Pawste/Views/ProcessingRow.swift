import SwiftUI

// 图片处理中显示的占位行
//
// 用户复制图片到剪贴板后，ImageProcessor actor 会异步解码/写盘/生成缩略图
// 这段处理期间（通常几十~几百毫秒）在列表顶部显示这个占位条
// 处理完成后 watcher.isProcessingImage 变 false，占位行自动消失
struct ProcessingRow: View {
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
                        .foregroundStyle(.glassTertiary)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text("处理图片中…")
                    .font(.system(size: 12))
                    .foregroundStyle(.glassSecondary)
                Text("稍候片刻")
                    .font(.system(size: 10))
                    .foregroundStyle(.glassTertiary)
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

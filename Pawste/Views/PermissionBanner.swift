import SwiftUI
import AppKit

// 辅助功能权限缺失时显示在列表顶部的警示条
//
// 为什么需要它：粘贴链路的最后一步（模拟 ⌘V）依赖辅助功能权限，
// 权限缺失时回车"看起来什么都没发生"（内容其实已写入剪贴板）——
// 静默失败是最差的体验，用户只能猜。这里把状态显式亮出来，
// 并提供一键直达系统设置开关的入口。授权完成后横幅自动消失（每次开窗重检）。
struct PermissionBanner: View {

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("未开启辅助功能，无法自动粘贴")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.glassPrimary)
                Text("回车后内容已在剪贴板，可手动 ⌘V")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.glassTertiary)
            }

            Spacer(minLength: 6)

            Button("去开启") {
                openAccessibilitySettings()
            }
            .font(.system(size: 11))
            .controlSize(.small)
            .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.12))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // 触发系统授权弹窗 + 直接打开 系统设置 → 隐私与安全性 → 辅助功能
    // 两者并行：系统弹窗只在"未询问过"时出现（问过/拒绝过则静默），
    // 深链保证任何状态下都能把用户带到正确的开关前
    private func openAccessibilitySettings() {
        Paster.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

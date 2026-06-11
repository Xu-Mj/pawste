import SwiftUI
import AppKit

// 关于页（嵌在 popup 浮窗里，不是独立窗口）
//
// 和 SettingsView 一样作为 ContentView 的一种模式（PanelUIState.mode == .about）
// 好处：完全继承 popup 的焦点、玻璃效果、键盘路由，没有第二个窗口
//   → 不存在"独立 About 窗口失焦销毁/影响剪贴板渲染"那一类问题
//
// 外层玻璃 + frame 由 ContentView 统一管理，这里只画内容
struct AboutView: View {

    // 返回回调：点返回按钮 / 按 Esc（Esc 在 ContentView 外层统一处理）
    let onBack: () -> Void

    // 从 Bundle 读版本号（构建时由 MARKETING_VERSION / CURRENT_PROJECT_VERSION 注入）
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private let githubURL = URL(string: "https://github.com/Xu-Mj/pawste")!

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            card
            Spacer(minLength: 0)
            footer
        }
    }

    // MARK: - 顶栏（返回按钮，复用 SettingsView 的样式）

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("返回剪贴板")
            .pointerCursor()

            Text("关于")
                .font(.system(size: 13, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 主卡片（图标 + 名称 + 版本 + 标语）

    private var card: some View {
        VStack(spacing: 12) {
            // App 图标：直接用真实应用图标（猫爪）
            // NSApp.applicationIconImage 运行时读 asset catalog 的 AppIcon
            // 图标自带圆角，直接展示即可
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            VStack(spacing: 3) {
                Text("Pawste")
                    .font(.system(size: 20, weight: .semibold))

                Text("版本 \(version) (\(build))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("Spotlight 风的 macOS 剪贴板管理器")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - 底栏（GitHub 链接 + 版权）

    private var footer: some View {
        VStack(spacing: 6) {
            Link(destination: githubURL) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                    Text("Xu-Mj/pawste")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tint)
            }
            .pointerCursor()

            Text("MIT License")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 16)
    }
}

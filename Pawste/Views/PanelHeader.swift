import SwiftUI

// popup 内嵌页面（设置 / 关于）共用的顶栏：圆形返回按钮 + 标题
// 之前 SettingsView / AboutView 各写了一份一模一样的，抽出来保证样式同步演进
struct PanelHeader: View {

    let title: String
    // 返回回调：点返回按钮时调用（Esc 由 ContentView 外层键盘路由统一处理）
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.glassPrimary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Color.glassPrimary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("返回剪贴板")
            .pointerCursor()

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

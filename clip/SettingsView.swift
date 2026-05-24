import SwiftUI
import ServiceManagement
import KeyboardShortcuts

// 偏好设置面板
//
// 通过 SwiftUI 的 Settings { ... } scene 集成进 App：
//   - 用户按 ⌘, 或菜单点 "Clip → 偏好设置" 时弹出
//   - 我们也手动在状态栏右键菜单提供入口
//
// 持有 watcher 引用以读写容量上限
// @Observable class 直接当属性传，SwiftUI 自动追踪变化
struct SettingsView: View {

    let watcher: PasteboardWatcher

    // === 本地 State：UI 即时反馈用 ===
    //
    // SwiftUI 控件（Toggle / Stepper）需要 Binding（双向绑定）
    // 因为 PasteboardWatcher 的 setXxx 方法不能直接给 Binding 用，
    // 这里搭一层本地 @State，onChange 时再把值传给 watcher
    //
    // 初始值在 init 里同步 watcher 的当前设置
    @State private var maxItems: Int
    @State private var maxImages: Int
    @State private var launchAtLogin: Bool

    init(watcher: PasteboardWatcher) {
        self.watcher = watcher
        _maxItems = State(initialValue: watcher.maxItems)
        _maxImages = State(initialValue: watcher.maxImages)
        // SMAppService.mainApp.status 返回 .enabled / .notRegistered 等
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        // Form + .formStyle(.grouped) ：标准 macOS 设置面板长相
        // 自动分组、间距、对齐 macOS 系统设置的视觉
        Form {
            generalSection
            shortcutSection
            capacitySection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
    }

    // MARK: - 分组

    private var generalSection: some View {
        Section("常规") {
            Toggle("开机自动启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    toggleLaunchAtLogin(newValue)
                }
        }
    }

    private var shortcutSection: some View {
        Section("快捷键") {
            // KeyboardShortcuts 库自带的 SwiftUI 录制控件
            // 用户点击 → 显示"按下你想要的快捷键" → 按完自动持久化到 UserDefaults
            // 重启 App 后自动应用，零额外代码
            KeyboardShortcuts.Recorder("呼出剪贴板：", name: .toggleClip)
        }
    }

    private var capacitySection: some View {
        Section("容量") {
            Stepper(value: $maxItems, in: 20...500, step: 10) {
                LabeledContent("文本条数上限") {
                    Text("\(maxItems)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: maxItems) { _, newValue in
                watcher.setMaxItems(newValue)
            }

            Stepper(value: $maxImages, in: 5...100, step: 5) {
                LabeledContent("图片张数上限") {
                    Text("\(maxImages)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: maxImages) { _, newValue in
                watcher.setMaxImages(newValue)
            }
        }
    }

    // MARK: - 自启动

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
                print("🔔 已开启开机自启动")
            } else {
                try SMAppService.mainApp.unregister()
                print("🔕 已关闭开机自启动")
            }
        } catch {
            // 常见失败：调试构建路径不稳定 / 签名问题
            // 出错时把 toggle 状态回滚到真实系统状态，避免 UI 谎报
            print("⚠️ 自启动操作失败: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

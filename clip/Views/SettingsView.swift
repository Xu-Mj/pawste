import SwiftUI
import ServiceManagement
import KeyboardShortcuts

// 偏好设置视图（嵌在 popup 浮窗里，不是独立窗口）
//
// 重大架构变更：不再是独立的 NSWindow / NSPanel
// 现在作为 ContentView 的一种模式存在，由 PanelUIState.mode 切换
// 好处：完全继承 popup 的焦点、玻璃效果、快捷键路由
struct SettingsView: View {

    let watcher: PasteboardWatcher
    // 返回回调：用户点返回按钮 / 按 Esc 时调用，由上层切回 .list 模式
    let onBack: () -> Void

    @State private var maxItems: Int
    @State private var maxImages: Int
    @State private var maxPinned: Int
    @State private var launchAtLogin: Bool

    // 快捷键录制模式：true 时显示 Recorder，false 时显示只读字串
    // Recorder 只在录制状态下存在于 view 树，平时销毁 → 全局 hotkey 始终工作
    @State private var isRecordingShortcut = false

    init(watcher: PasteboardWatcher, onBack: @escaping () -> Void) {
        self.watcher = watcher
        self.onBack = onBack
        _maxItems = State(initialValue: watcher.maxItems)
        _maxImages = State(initialValue: watcher.maxImages)
        _maxPinned = State(initialValue: watcher.maxPinned)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                generalSection
                shortcutSection
                capacitySection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        // 注意：不再设 .glassEffect 和 .frame
        // 这些由 ContentView（外层容器）统一管理，避免双层玻璃叠加
    }

    // MARK: - 顶栏（带返回按钮）

    private var header: some View {
        HStack(spacing: 8) {
            // 返回按钮（左上）
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

            Text("偏好设置")
                .font(.system(size: 13, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 设置分组

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
            // 关键设计：Recorder 控件只在录制态下挂载，平时销毁
            //
            // 为什么不能始终显示 Recorder：
            //   Recorder 渲染到屏幕上时，KeyboardShortcuts 库自动把全局 hotkey 暂停
            //   （避免用户录制时旧快捷键触发干扰）
            //   后果是 settings 永远开着 = hotkey 永远废
            //
            // 现在的方式：
            //   - 默认：只读显示当前快捷键 + "修改"按钮
            //   - 点"修改"：isRecordingShortcut = true，挂载 Recorder
            //     这几秒钟里 hotkey 是暂停的（合理：用户正在录制）
            //   - 录完点"完成"：isRecordingShortcut = false，Recorder 销毁，hotkey 恢复
            if isRecordingShortcut {
                recordingMode
            } else {
                displayMode
            }
        }
    }

    // 显示态：当前快捷键 + "修改"按钮
    private var displayMode: some View {
        LabeledContent("呼出剪贴板") {
            HStack(spacing: 8) {
                Text(currentShortcutDisplay)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button("修改") {
                    isRecordingShortcut = true
                }
                .controlSize(.small)
                .pointerCursor()
            }
        }
    }

    // 录制态：Recorder + "完成"按钮
    private var recordingMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyboardShortcuts.Recorder("呼出剪贴板：", name: .toggleClip)

            HStack {
                Text("点上面字段，按下你想要的快捷键组合")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("完成") {
                    isRecordingShortcut = false
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
            }
        }
    }

    // 当前快捷键的可视化字符串
    // KeyboardShortcuts.Shortcut 的 description 给出像 "⌥V" 这种简洁形式
    private var currentShortcutDisplay: String {
        KeyboardShortcuts.getShortcut(for: .toggleClip)?.description ?? "未设置"
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

            Stepper(value: $maxPinned, in: 1...20, step: 1) {
                LabeledContent("置顶条数上限") {
                    Text("\(maxPinned)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: maxPinned) { _, newValue in
                watcher.setMaxPinned(newValue)
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
            print("⚠️ 自启动操作失败: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

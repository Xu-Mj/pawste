import Observation

// 浮窗的 UI 模式状态
//
// 同一个 panel（FloatingPanel）承载两种模式：
//   - .list: 剪贴板历史列表（默认）
//   - .settings: 偏好设置表单
//
// 用 @Observable 让 SwiftUI 自动响应模式变化
// StatusBarController（AppKit 侧）和 ContentView（SwiftUI 侧）共享同一个实例
@Observable
final class PanelUIState {
    enum Mode {
        case list      // 剪贴板列表
        case settings  // 偏好设置
    }

    var mode: Mode = .list

    // 切回列表（关闭后默认）
    func resetToList() {
        mode = .list
    }
}

import AppKit
import SwiftUI

// 菜单栏图标 + 浮窗的总指挥
@MainActor
final class StatusBarController {

    // MARK: - 持有的资源

    private let statusItem: NSStatusItem
    private let panel: FloatingPanel
    private let watcher: PasteboardWatcher

    private var globalMouseMonitor: Any?

    // 弹窗弹出时记下"原来在前台的 App"，关闭时把焦点还回去
    // 这样我们能精准把模拟的 ⌘V 送到对的 App
    private var previousApp: NSRunningApplication?

    // 浮窗固定尺寸
    private let panelSize = CGSize(width: 360, height: 480)

    // MARK: - 初始化

    init(watcher: PasteboardWatcher) {
        self.watcher = watcher

        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        self.panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        configureStatusItem()
    }

    // MARK: - 配置

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // 关掉系统级阴影：因为 panel 是矩形、可见的 SwiftUI 内容是圆角玻璃，
        // 系统阴影画在矩形边界外，会在 4 个角"泄漏"出 panel 背景
        // Liquid Glass 自己有微妙的边缘高光做视觉分离，不需要外部阴影
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 注意：彻底拿掉了 NSVisualEffectView！
        // 现在背景由 SwiftUI 用 macOS 26 的 .glassEffect() 直接渲染，等于走系统级 Liquid Glass 管线
        // 顺带好处：层次简化，layout 递归 warning 大概率消失
        //
        // panel.contentView 直接是 NSHostingView，没中间层
        let rootView = ContentView(
            watcher: watcher,
            onSelect: { [weak self] text in
                self?.handleItemSelection(text)
            },
            onDismiss: { [weak self] in
                self?.hidePanel()
            }
        )
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: "剪贴板历史"
        )
        button.action = #selector(handleStatusItemClick)
        button.target = self
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    // MARK: - 显示控制

    func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // 记下当前前台 App，关闭弹窗后我们要把焦点还给它
        // 排除自己（避免快速 toggle 时把自己记成 previousApp）
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }

        let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)
        let x = buttonScreenFrame.midX - panelSize.width / 2
        let y = buttonScreenFrame.minY - panelSize.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        // 关键修复：不要 NSApp.activate(ignoringOtherApps: true)
        // .nonactivatingPanel 本来就是"不抢前台"的设计；之前那行把好处砸了
        //
        // FloatingPanel.canBecomeKey = true 让 panel 能接收键盘事件
        // 不需要 App 变 active 也能接收 —— 关键 window != active App
        panel.makeKeyAndOrderFront(nil)

        installEventMonitors()
    }

    func hidePanel() {
        panel.orderOut(nil)
        removeEventMonitors()
    }

    // MARK: - 选择 → 粘贴流程

    private func handleItemSelection(_ text: String) {
        print("🎯 选中: \(text.prefix(40))")
        print("   目标 App: \(previousApp?.localizedName ?? "<nil>") (\(previousApp?.bundleIdentifier ?? "<nil>"))")
        print("   辅助功能权限: \(Paster.hasAccessibilityPermission ? "✅ 已授予" : "❌ 未授予")")

        // 1. 写回系统剪贴板
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 2. 记下要粘贴到哪个 App（隐藏 panel 后 frontmostApplication 可能变）
        let targetApp = previousApp

        // 3. 隐藏 panel
        hidePanel()

        // 4. 显式激活目标 App，确保焦点回到它的输入框
        //    然后等焦点真正切回去（系统调度需要时间），最后发 ⌘V
        Task { @MainActor in
            // NSRunningApplication.activate() —— macOS 14+ 推荐的新形式（无参数）
            targetApp?.activate()
            print("   → 已激活目标 App")

            // 等焦点切换完成
            try? await Task.sleep(for: .milliseconds(80))

            Paster.simulatePaste()
        }
    }

    // MARK: - 事件处理

    @objc private func handleStatusItemClick() {
        togglePanel()
    }

    private func installEventMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hidePanelIfClickOutsideStatusItem()
        }
    }

    private func removeEventMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
    }

    private func hidePanelIfClickOutsideStatusItem() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else {
            hidePanel()
            return
        }
        let buttonScreenFrame = buttonWindow.convertToScreen(button.frame)
        let clickLocation = NSEvent.mouseLocation
        if buttonScreenFrame.contains(clickLocation) {
            return
        }
        hidePanel()
    }
}

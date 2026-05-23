import AppKit
import SwiftUI
import ServiceManagement   // SMAppService 注册登录项

// 菜单栏图标 + 浮窗的总指挥
@MainActor
final class StatusBarController {

    // MARK: - 持有的资源

    private let statusItem: NSStatusItem
    private let panel: FloatingPanel
    private let watcher: PasteboardWatcher

    // 强持有 NSHostingController：它持有的 view 是 panel.contentView
    // 但 NSWindow 只弱持有 NSViewController，所以必须我们自己持有
    // 不持有的话 controller 会被 ARC 释放，SwiftUI 状态丢失
    private var hostingController: NSHostingController<ContentView>?

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
        // 允许从窗口背景任意位置拖动（不只是 titleBar）
        // 由于 SwiftUI 里 Button 会"吃掉"鼠标事件，拖动只会从空白区（标题、footer 等）生效
        // 点击 item / 按钮不会误触拖动，恰好是我们想要的行为
        panel.isMovableByWindowBackground = true

        // 背景由 SwiftUI 用 macOS 26 的 .glassEffect() 直接渲染（Liquid Glass 管线）
        //
        // 用 NSHostingController 而不是 NSHostingView：
        //   - NSHostingController 是 NSViewController 子类，对 SwiftUI 生命周期管理更完整
        //   - 它在 view 即将 layout / 已 layout 等关键节点上有更细致的协调
        //   - 经验上能解决"layout 中又触发 layout"的递归 warning
        //   - Apple 在 macOS 14+ 推荐这种方式做 SwiftUI ↔ AppKit 嵌入
        //
        // onSelect 接收完整 ClipboardItem（图片需要 ImageEntry 元数据）
        let rootView = ContentView(
            watcher: watcher,
            onSelect: { [weak self] item in
                self?.handleItemSelection(item)
            },
            onDismiss: { [weak self] in
                self?.hidePanel()
            }
        )
        let controller = NSHostingController(rootView: rootView)
        // sizingOptions = []：不让 controller 把 SwiftUI 的尺寸偏好往外传
        // 让 panel.contentRect 决定一切，避免 SwiftUI 内部尺寸协商反推外层 frame
        controller.sizingOptions = []
        controller.view.frame = NSRect(origin: .zero, size: panelSize)
        // 让 controller 的 view 自动跟随 panel 尺寸变化（虽然我们目前不变 panel 尺寸）
        controller.view.autoresizingMask = [.width, .height]

        panel.contentView = controller.view

        // 强持有 controller：NSWindow 只弱持有 viewController，不持有 ARC 会释放
        self.hostingController = controller
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
        // 记下当前前台 App，关闭弹窗后我们要把焦点还给它
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }

        // 每次打开都定位到鼠标附近，让浮窗"跟着用户走"
        // 内部会自动 clamp 到当前屏幕的可见区域，不会跑出屏幕
        panel.setFrameOrigin(panelOriginNearMouse())

        // .nonactivatingPanel + FloatingPanel.canBecomeKey 让 panel 能收键盘事件但不抢 App 焦点
        panel.makeKeyAndOrderFront(nil)

        installEventMonitors()
    }

    func hidePanel() {
        panel.orderOut(nil)
        removeEventMonitors()
    }

    // MARK: - 位置计算

    // 计算"鼠标附近"的浮窗原点
    //
    // 策略：让 panel 的中心对齐鼠标位置，然后裁剪到当前屏幕的可见区域
    // 这样无论鼠标在屏幕哪个角落，浮窗都不会跑出屏幕
    //
    // 多显示器适配：以鼠标所在的那块屏幕的 visibleFrame 为准
    private func panelOriginNearMouse() -> NSPoint {
        let mouse = NSEvent.mouseLocation

        // 找鼠标在哪块屏幕（visibleFrame 排除 Dock / 菜单栏占用区）
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let bounds = screen.visibleFrame

        // panel 中心对齐鼠标
        var origin = NSPoint(
            x: mouse.x - panelSize.width / 2,
            y: mouse.y - panelSize.height / 2
        )

        // Clamp 到屏幕可见区域，留 8pt 边距让浮窗别贴边
        let margin: CGFloat = 8
        origin.x = max(bounds.minX + margin,
                       min(bounds.maxX - panelSize.width - margin, origin.x))
        origin.y = max(bounds.minY + margin,
                       min(bounds.maxY - panelSize.height - margin, origin.y))

        return origin
    }

    // MARK: - 选择 → 粘贴流程

    private func handleItemSelection(_ item: ClipboardItem) {
        let targetApp = previousApp
        print("🎯 选中条目，目标 App: \(targetApp?.localizedName ?? "<nil>")")

        // 写剪贴板 + 隐藏 panel + 模拟粘贴 整套包成一个 Task
        // 因为图片场景需要 async 读盘
        Task { @MainActor in
            // 1. 写剪贴板（按类型分发）
            switch item.kind {
            case .text(let text):
                writeTextToPasteboard(text)
            case .image(let entry):
                await writeImageToPasteboard(entry)
            }

            // 2. 隐藏 panel
            hidePanel()

            // 3. 激活目标 App
            targetApp?.activate()

            // 4. 等焦点切换完成
            try? await Task.sleep(for: .milliseconds(80))

            // 5. 模拟 ⌘V
            Paster.simulatePaste()
        }
    }

    private func writeTextToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // 写图片到剪贴板：同时写 PNG 数据 + 文件名文本作 fallback
    // 多类型共存是 NSPasteboard 的正常用法，App 各取所需：
    //   - 接受图片的 App（如 Pages、备忘录）→ 拿 PNG
    //   - 不接受图片的 App（如 Terminal）→ 拿文本（文件名 + 尺寸）
    private func writeImageToPasteboard(_ entry: ClipboardItem.ImageEntry) async {
        let pb = NSPasteboard.general
        pb.clearContents()

        // 从磁盘加载原图 PNG
        guard let data = await watcher.loadImageData(filename: entry.filename) else {
            print("⚠️ 图片文件丢失: \(entry.filename)")
            pb.setString(entry.displayName, forType: .string)
            return
        }

        // 写 PNG 数据
        pb.setData(data, forType: .png)

        // 同时写描述文本作 fallback
        let fallbackText = "\(entry.displayName) (\(entry.width)×\(entry.height))"
        pb.setString(fallbackText, forType: .string)
    }

    // MARK: - 事件处理

    @objc private func handleStatusItemClick() {
        // 区分左右键：左键开关浮窗，右键弹设置菜单
        // NSApp.currentEvent 在 action 回调里能拿到触发的那个事件
        if NSApp.currentEvent?.type == .rightMouseDown {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    // MARK: - 右键菜单 + 开机自启动

    private func showContextMenu() {
        guard let button = statusItem.button else { return }

        let menu = NSMenu()

        // 开机自启动开关
        let launchItem = NSMenuItem(
            title: "开机自动启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        // state: 控制菜单项左边那个 ✓ 标记
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Clip",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // popUp(positioning:at:in:) 在指定 view 的指定坐标弹出菜单
        // at: NSPoint 是相对 button 内部坐标（左下角原点）
        // button.bounds.height 是顶端，菜单从这里向下展开
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    // 当前是否已注册开机自启动
    // SMAppService.mainApp 是 macOS 13+ 的现代 API，对应自身这个 App
    // .status 返回 .enabled / .notRegistered / .notFound / .requiresApproval
    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
                print("🔕 已关闭开机自启动")
            } else {
                try SMAppService.mainApp.register()
                print("🔔 已开启开机自启动")
            }
        } catch {
            // 常见失败原因：
            //   - 调试构建路径在 DerivedData 里，系统认为这不是合法 App
            //   - 未签名 / 签名身份变化导致 TCC 拒绝
            // 生产构建（放进 /Applications + 有 Developer ID 签名）就不会这样
            print("⚠️ 自启动操作失败: \(error.localizedDescription)")
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
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

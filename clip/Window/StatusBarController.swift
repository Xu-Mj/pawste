import AppKit
import SwiftUI

// 菜单栏图标 + 浮窗的总指挥
@MainActor
final class StatusBarController {

    // MARK: - 持有的资源

    private let statusItem: NSStatusItem
    private let panel: FloatingPanel
    private let watcher: PasteboardWatcher

    // 强持有 NSHostingController（NSWindow 只弱引用 viewController）
    private var hostingController: NSHostingController<ContentView>?

    // 共享 UI 状态（list / settings 模式切换）
    // 让我们能从 AppKit 侧（右键菜单"偏好设置"）改变 SwiftUI 侧的视图模式
    private let uiState = PanelUIState()

    private var globalMouseMonitor: Any?

    // 弹窗弹出时记下"原来在前台的 App"，关闭时把焦点还回去
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
        // uiState 传进去，让 SwiftUI 能根据模式切换 list / settings 视图
        let rootView = ContentView(
            watcher: watcher,
            uiState: uiState,
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
        // 候选 SF Symbol：
        //   doc.on.clipboard / doc.on.clipboard.fill —— 文档放剪贴板上
        //   list.clipboard / list.clipboard.fill     —— 清单 + 剪贴板（管理器语义）
        //   rectangle.on.rectangle.fill              —— 两方块叠加（复制感）
        //   paperclip                                —— 回形针（"Clip"双关）
        // 改 systemSymbolName 字符串即可切换
        button.image = NSImage(
            systemSymbolName: "list.clipboard.fill",
            accessibilityDescription: "剪贴板历史"
        )
        button.action = #selector(handleStatusItemClick)
        button.target = self
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    // MARK: - 显示控制

    func togglePanel() {
        // 不管什么模式，⌥+V / 状态栏点击都按"clipboard list"模式打开
        // 如果当前在 settings 模式，切回 list；如果已经是 list，按原逻辑 toggle
        if panel.isVisible && uiState.mode == .settings {
            uiState.mode = .list
            return
        }

        if panel.isVisible {
            hidePanel()
        } else {
            uiState.mode = .list   // 保证打开时是 list 模式
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

    // 写图片到剪贴板：只写 PNG 数据，不写 fallback 文本
    //
    // 之前同时写 PNG + 文件名文本，结果"文本优先"的 App（备忘录、TextEdit、Notion）
    // 把文件名而不是图片粘出来。用户明确要求"只粘图片不粘名称"。
    //
    // 副作用：粘到完全不支持图片的 App（Terminal）时什么都不发生
    // —— 这是合理的，用户知道终端粘不了图
    private func writeImageToPasteboard(_ entry: ClipboardItem.ImageEntry) async {
        let pb = NSPasteboard.general
        pb.clearContents()

        guard let data = await watcher.loadImageData(filename: entry.filename) else {
            print("⚠️ 图片文件丢失: \(entry.filename)")
            return  // 文件丢失就什么都不写，simulatePaste 等于 no-op
        }

        pb.setData(data, forType: .png)
    }

    // MARK: - 事件处理

    @objc private func handleStatusItemClick() {
        if NSApp.currentEvent?.type == .rightMouseDown {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    // MARK: - 右键菜单

    private func showContextMenu() {
        guard let button = statusItem.button else { return }

        let menu = NSMenu()

        // 关于 Clip 暂时注释掉：和之前 settings 一样栽在"NSMenu action → 新窗口"过渡 bug 上
        // 系统标准 About 面板从这条路径触发也会进入半 key 状态
        // 将来改成"嵌进 popup 的 .about 模式"（类似 settings）就能彻底绕开
        //
        // let aboutItem = NSMenuItem(
        //     title: "关于 Clip",
        //     action: #selector(showAbout),
        //     keyEquivalent: ""
        // )
        // aboutItem.target = self
        // menu.addItem(aboutItem)
        // menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Clip",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )

        button.isHighlighted = false
    }

    // 关于 Clip：直接用系统标准 About 面板
    //
    // 为什么不自画一个：
    //   - 系统 About 面板长得就是 macOS 用户熟悉的样子（App 图标 + 版本 + credits）
    //   - 自动读 Info.plist 的 CFBundleShortVersionString / CFBundleVersion 字段
    //   - 不像我们之前 settings 的自定义窗口，About 是只读 + transient，焦点问题不重要
    //   - 一行 API 搞定
    //
    // credits 接 NSAttributedString，可以塞富文本和超链接（.link 属性）
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: aboutCredits()
        ])
    }

    private func aboutCredits() -> NSAttributedString {
        let credits = NSMutableAttributedString()

        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
        let secondaryAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://github.com/Xu-Mj/clip")!
        ]

        credits.append(NSAttributedString(
            string: "Spotlight 风的 macOS 剪贴板管理器\n\n",
            attributes: bodyAttrs
        ))
        credits.append(NSAttributedString(
            string: "GitHub: ",
            attributes: secondaryAttrs
        ))
        credits.append(NSAttributedString(
            string: "Xu-Mj/clip",
            attributes: linkAttrs
        ))

        return credits
    }

    // openSettings 已废弃：偏好设置入口移到了 popup 内部的齿轮按钮
    // 保留这个方法只是因为 #selector 不容易完全清除，留个 noop 也无害
    // 实际触发现在是 SwiftUI 内 uiState.mode = .settings 直接切换
    @objc private func openSettings() {
        // 已不再使用
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

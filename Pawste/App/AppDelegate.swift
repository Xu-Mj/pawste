import AppKit
import KeyboardShortcuts

// AppKit 的 App 生命周期入口
//
// NSObject：所有 AppKit 类的根基类，配合 Objective-C 运行时必须
// NSApplicationDelegate：协议，约定 App 启动/退出等回调
final class AppDelegate: NSObject, NSApplicationDelegate {

    // App 持有的核心服务
    // let：constant，App 整个生命周期只创建一次
    let watcher = PasteboardWatcher()

    // StatusBarController 需要在 applicationDidFinishLaunching 里创建
    // 因为它要操作 NSStatusBar，而那时系统才完全就绪
    // 所以这里先声明为 var Optional
    var statusBarController: StatusBarController?

    // MARK: - App 生命周期

    // App 启动完成后系统调用这个方法
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 启动剪贴板监听
        watcher.start()

        // 2. 创建状态栏控制器
        // 注意：StatusBarController 标了 @MainActor，所以这里编译器会要求
        // 当前上下文也在主线程。applicationDidFinishLaunching 确实是主线程，OK
        statusBarController = StatusBarController(watcher: watcher)

        // 3. 注册全局快捷键
        // KeyboardShortcuts.onKeyDown(for:) 在指定快捷键被按下时调用闭包
        // 内部用的是 Carbon HotKey API，不需要"辅助功能权限"
        //
        // [weak self]：捕获 self 时声明弱引用，避免循环引用（虽然 AppDelegate 几乎永远存活，但好习惯）
        KeyboardShortcuts.onKeyDown(for: .togglePawste) { [weak self] in
            self?.statusBarController?.togglePanel()
        }

        // 4. 辅助功能权限：缺失时启动即主动发起系统授权请求，不等用户撞上"粘贴没反应"
        // 系统弹窗只在"未询问过"状态出现（问过/拒绝过则静默无副作用），每次启动调用是安全的；
        // 弹窗之外还有 popup 里的常驻 PermissionBanner 兜底引导（任何状态可见、可点去开启）
        if !Paster.hasAccessibilityPermission {
            Paster.requestAccessibilityPermission()
            log("🔐 缺少辅助功能权限，已发起系统授权请求")
        }

        log("🚀 Pawste 启动完成，全局快捷键 ⌥+V 已注册")
    }

    // App 即将退出时调用
    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        // 关键：同步落盘，确保最后的变更被保存
        // 防抖保存可能还在 1 秒等待中，不 flush 就会丢
        watcher.flushSave()
        log("👋 Pawste 退出，历史已保存")
    }
}

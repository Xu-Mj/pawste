# Clip

[![Build](https://github.com/Xu-Mj/clip/actions/workflows/build.yml/badge.svg)](https://github.com/Xu-Mj/clip/actions/workflows/build.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

> Spotlight 风的 macOS 剪贴板管理器。Swift + AppKit + SwiftUI 混合实现，专为 macOS 26 (Tahoe) 的 Liquid Glass 设计。

<p align="center">
  <i>（截图待补）</i>
</p>

---

## ✨ 特性

- ⚡ **全局快捷键** `⌥+V` —— 任意 App、任意位置即时唤起
- 📋 **双类型支持** —— 文本 + 图片（PNG / JPEG / TIFF / GIF / BMP / HEIC，统一转 PNG 存）
- 🔢 **数字快捷键** —— `1`-`9` 直接粘贴对应位置的条目
- ↑↓ **键盘导航** —— `Enter` 自动粘贴到原 App 输入框（无需手动 ⌘V）
- 🎨 **Liquid Glass** —— macOS 26 同款渲染管线，浮窗自带磨砂玻璃质感
- 🖱️ **鼠标位置定位** —— 浮窗跟着鼠标走，多显示器自动适配
- 🪟 **可拖动** —— 想钉在某处就拖过去
- 💾 **本地持久化** —— JSON 文件，重启不丢；图片单独文件，按需加载
- 📐 **容量可配** —— 文本 20-500 条 / 图片 5-100 张，独立上限
- 🔑 **自定义快捷键** —— 按需录制，平时不干扰全局 hotkey
- 🚀 **开机自启动** —— 一键开关
- 🍃 **极致轻量** —— 内存常驻 < 100MB，CPU 待机几乎 0

---

## 🚀 使用

当前是开发期，从 Xcode 跑：

1. 用 Xcode 打开 `clip.xcodeproj`
2. `⌘R` 运行
3. 首次按 `Enter` 粘贴时会要求**辅助功能权限**：系统设置 → 隐私与安全性 → 辅助功能 → 加入 clip
4. 之后随时 `⌥+V` 唤出

**操作速查**：

| 快捷键 | 行为 |
|---|---|
| `⌥+V` | 唤出 / 隐藏 popup |
| `↑` `↓` | 列表内移动选择 |
| `Enter` | 粘贴选中条目到原 App |
| `1`-`9` | 直接粘贴对应位置条目 |
| `Esc` | 关闭 popup / 设置返回列表 |
| 点齿轮 ⚙️ | 进入偏好设置 |
| 右键状态栏 | 弹出退出菜单 |

---

## 🏗️ 架构

文件清单：

| 文件 | 职责 |
|---|---|
| `clipApp.swift` | SwiftUI `App` 入口，桥接 AppKit Delegate |
| `AppDelegate.swift` | App 生命周期，启动 watcher，注册全局快捷键 |
| `PasteboardWatcher.swift` | 轮询 NSPasteboard，存储历史，去重，evict |
| `ImageProcessor.swift` | 图片 actor，异步处理（解码 / 写盘 / 缩略图） |
| `ClipboardItem.swift` | 数据模型，含 `Kind = .text \| .image` 枚举 |
| `StatusBarController.swift` | 菜单栏图标 + popup 浮窗 + 事件路由 |
| `FloatingPanel.swift` | 自定义 NSPanel 子类（borderless + canBecomeKey） |
| `ContentView.swift` | SwiftUI 浮窗内容，根据模式渲染 list 或 settings |
| `SettingsView.swift` | SwiftUI 设置表单 |
| `PanelUIState.swift` | 共享 UI 状态（list / settings 模式切换） |
| `Paster.swift` | CGEvent 模拟 ⌘V，含辅助功能权限检查 |
| `GlobalShortcuts.swift` | KeyboardShortcuts 库快捷键定义 |

---

## 🧭 关键设计决定与踩过的坑

按时间顺序记录，给未来的自己看，也给从 Rust/其他平台转 Swift 的人参考。

### 1. NSPanel + `.nonactivatingPanel` for popup
浮窗用 NSPanel 而非 NSWindow。`.nonactivatingPanel` style mask 让浮窗能拿键盘焦点但不激活整个 App—— 这是菜单栏 App 弹"浮岛"的标准配方。

### 2. `FloatingPanel.canBecomeKey = true` 覆写
默认 borderless NSPanel `canBecomeKey` 返回 NO，必须显式覆写。否则 `makeKeyAndOrderFront` 抛 warning，Esc 等键盘事件收不到。

### 3. 鼠标定位 vs 文本光标定位
本来想做"浮窗弹到文本光标处"（Raycast 风），需要走 AX API 查询当前 focused element 的 bounds。**实测下来**：
- AX 在 Apple 自家 App（备忘录、TextEdit）OK
- 在 Electron / Web App / Terminal 等大量场景失败
- 调试构建权限不稳定，迭代摩擦极大
- ROI 低（鼠标位置已经能覆盖 99% 体验）

**决定**：弃 caret 检测，固定鼠标定位。鼠标在哪儿浮窗就在哪儿，可拖。

### 4. 文本粘贴自动注入（`CGEvent.post`）
选中条目后不只把内容写回 NSPasteboard，还**模拟 ⌘V 自动粘贴到原 App**——这是剪贴板工具好用的关键。

实现：
- 弹窗前 `previousApp = NSWorkspace.shared.frontmostApplication`
- 关弹窗后 `previousApp?.activate()`
- 80ms 后 `CGEvent` 发送 ⌘V 键盘事件

需要"辅助功能"权限（系统级，非 entitlement）。

### 5. 轮询 changeCount + 邻接去重
macOS NSPasteboard 没有 push 通知 API（iOS 有），只能轮询 `changeCount`。**和 Maccy / Paste / Raycast 一致**——这不是偷懒，是 Apple 没留接口。

去重两层：
- **sourcePath 去重**（针对 Finder 反复复制同一文件）—— O(1) 路径比较
- **邻接指纹去重**（针对截图等纯数据复制，size + 前 256 字节）—— O(1)

最初尝试过全局 SHA256 hash 去重（5-500ms 同步代价），用户反对："磁盘占用必须给延迟让位"。**砍掉 hash**，接受同图复制多次 = 多份文件，磁盘代价远小于响应延迟。

### 6. 图片 actor + 异步处理
Swift Concurrency `actor` 天然串行化 + 后台线程。所有耗时操作（解码、PNG 编码、写盘、生成缩略图）在 actor 上跑：

```swift
actor ImageProcessor {
    func process(data: Data, sourcePath: String?) -> ImageEntry? { ... }
}

// 调用方
Task { @MainActor in
    let entry = await imageProcessor.process(...)
    items.insert(...)   // 回到主线程更新 UI
}
```

UI 在处理期间显示一条"loading"占位行，处理完替换成真实条目。**任何场景都不卡主线程**。

### 7. `@Observable` + 简洁状态追踪
Swift 5.9 引入的 `@Observable` 宏替代旧 `ObservableObject + @Published`。任何 SwiftUI View 读到的 `@Observable` 类属性自动订阅，零样板代码。`watcher.items` 一变 UI 立刻刷新。

### 8. Liquid Glass via `.glassEffect`
macOS 26 全新 API，比传统 NSVisualEffectView 视觉更通透、跟随系统主题更智能。**但有 bug**：
- 启动时一次性触发 `_NSDetectedLayoutRecursion` warning（SwiftUI + NSHostingController + 任何"真模糊"渲染都触发——`.glassEffect`、`.background(.material)`、NSVisualEffectView 全部）
- Apple 没修，warning 只一次、不影响功能。**接受**。

### 9. Settings 嵌入 popup（而不是独立窗口）
**这是最痛的迭代**。一开始想给设置做独立 NSWindow，遇到一连串问题：
- borderless NSWindow 无法可靠拿到 key 焦点
- `setActivationPolicy(.regular)` 引起 Dock 残留 + 全局快捷键失效
- `NSPanel + .nonactivatingPanel` 让事件路由进半 key 状态
- `NSMenu action → 新 panel` 的过渡总有 timing bug

**最终方案**：设置 UI 作为 popup 的另一种"模式"存在，由 `PanelUIState.mode` 切换。同一个浮窗、同一个 key 状态、同一个事件路由——所有 NSWindow vs NSPanel 的纠结全部消失。

教训：**不要为了"和系统一致"硬上独立窗口模式**。LSUIElement App + 自定义浮窗的组合下，"标准 macOS 设置窗口"不是必选项。Spotlight、Raycast 也不用独立窗口。

### 10. `KeyboardShortcuts.Recorder` 按需挂载
快捷键录制控件 `KeyboardShortcuts.Recorder` 渲染到屏幕上时会**自动暂停全局 hotkey**（库的内部行为，避免和录制冲突）。

**坑**：把它挂在设置表单里常驻 → 一进设置全局 ⌥+V 就废了。

**正解**：只读显示当前快捷键 + "修改"按钮。点修改才挂载 Recorder（仅这几秒钟 hotkey 暂停），录完销毁 Recorder（hotkey 立刻恢复）。

### 11. JSON 持久化 + 外部图片文件
存历史用 JSON（Codable 原生支持），但**图片二进制不内联到 JSON**：
- 100 张图 × 平均 500KB = 50MB JSON，启动加载会卡
- 改成：图片单独存 `~/.../images/<uuid>.png`，JSON 只存元数据 + 40×40 缩略图
- 启动加载 JSON 极快，原图按需读

防抖保存：`Task` + `sleep` 实现，"最后一次变更后 1 秒"才真写盘。连续复制不会频繁 I/O。

---

## 🛠️ 技术栈

- **Swift 6** + **macOS 26.5+**（最低 deployment target）
- **SwiftUI**（UI 层）+ **AppKit**（窗口管理、菜单栏、事件监听）
- **Swift Concurrency**（async/await、Actor、@MainActor）
- **[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)** 库 by Sindre Sorhus
- **`@Observable`** 宏（Swift 5.9+）
- **`SMAppService`**（开机自启动，macOS 13+）
- **Liquid Glass `.glassEffect`**（macOS 26+）

---

## 🐛 已知问题

- 启动时 console 一次性 `_NSDetectedLayoutRecursion` warning（Apple SwiftUI + 真模糊渲染管线的 bug，不影响功能）
- 调试构建辅助功能权限偶尔需要重新授权（DerivedData 路径变化导致）—— 装到 /Applications 可解决

---

## 📦 未来 / TODO

- [ ] popup 里 `Delete` 键删除单条
- [ ] 置顶 / 收藏条目（不被 evict）
- [ ] App 图标精修（当前是 Xcode 默认）
- [ ] 签名 + 公证 + 打包分发（功能稳定后）
- [ ] GitHub Actions 自动构建
- [ ] About 窗口（版本号 / 作者）

---

## 📝 License

MIT

# Clip 项目复盘

> 一个 macOS 剪贴板管理器从无到有的工程决策日志。
>
> 这份文档不是 README——README 给用户看，这份给**未来的你**和**想从 Rust/其他平台转 Swift 的工程师**。每一个决策都附"上下文 / 备选 / 为什么这么选 / 踩了什么坑 / 学到什么"。

---

## 0. 起源与定位

- **背景**：日常用 Rust + Web，对 Mac 上"小而美的工具"有需求。试过 Raycast 觉得太重（200MB+ 内存），想做一个专精剪贴板的轻量替代。
- **学习目标**：作为 Rust 开发者，借机吃透 Swift + macOS App 开发栈。
- **技术选型纠结**：最初考虑 Rust + GPUI（gpui-chat 主项目同栈）。最终选 Swift 的理由：
  - macOS 原生 API 用 Rust 调（`objc2`）啰嗦，Swift 是一等公民
  - 系统集成（菜单栏、自启动、辅助功能、Liquid Glass）Swift 摩擦最小
  - 学习收益更大——Rust 已经会了，Swift 是新地图
- **结果**：Swift 这条路是对的。回顾整个项目，绝大多数复杂度都来自"macOS 系统 API 的特殊行为"，不是语言层面。Rust 写也会遇到一模一样的问题，还多一层 FFI 翻译。

---

## 1. AppKit + SwiftUI 混合架构

### 决策
**主框架 SwiftUI，窗口管理 / 菜单栏 / 全局快捷键用 AppKit，靠 `NSHostingView` / `NSHostingController` 桥接。**

### 上下文
SwiftUI 在 macOS 14+ 已经成熟，但**菜单栏 App** 这种场景天然偏 AppKit：`NSStatusItem` 是 AppKit API，没有纯 SwiftUI 替代品（`MenuBarExtra` 试过，下面单独说）。

### 备选
- 纯 SwiftUI（`MenuBarExtra`）—— 试过，弃用
- 纯 AppKit —— 工程量翻倍，UI 写起来回到 90 年代

### 为什么这么选
- UI 部分（列表、设置表单、玻璃效果）SwiftUI 写起来速度 3-5 倍快
- 窗口生命周期、键盘事件、Carbon HotKey 等 AppKit 现有方案最稳
- `NSHostingView(rootView: SwiftUIView)` 是万能逃生口，需要时把 SwiftUI 内容塞进任何 AppKit 容器

### 踩过的坑
- `MenuBarExtra`（SwiftUI 原生菜单栏 API）**没有"代码打开弹窗"的 public API**——只能用户点图标才弹。我们需要 `⌥+V` 全局唤起，所以早期就从 `MenuBarExtra` 切换到 `NSStatusItem + NSPanel`
- SwiftUI 状态（`@State` / `@Observable`）在 `NSHostingView` 里**生命周期偶尔诡异**——比如 `onAppear` 在 panel 还没显示时也可能触发
- macOS 26 的 `.glassEffect` 在 `NSHostingController` 容器里会触发一次 `_NSDetectedLayoutRecursion` warning（Apple bug，不影响功能，但删不掉）

### 教训
**SwiftUI 的"纯声明式"模型在涉及窗口管理时漏水。任何"窗口怎么显示、怎么 key、怎么和系统协作"的问题都要回 AppKit 找答案。** 别和 SwiftUI 框架对着干。

---

## 2. 浮窗：`NSPanel + .nonactivatingPanel + canBecomeKey` 覆写

### 决策
**剪贴板 popup 用 `FloatingPanel: NSPanel` 子类，styleMask 包含 `.nonactivatingPanel`，覆写 `canBecomeKey = true`。**

### 上下文
菜单栏 App 弹出来的"浮岛"要：
- 不抢前台 App 焦点（不然用户原本的输入框失焦）
- 能接收键盘事件（↑↓ 选 / Enter 粘）
- 不在 ⌘+Tab 切换列表里
- 不挡全屏 App

### 备选
- `NSWindow` —— `borderless` 风格下 `canBecomeKey` 默认 false，焦点拿不到
- `MenuBarExtra` —— 没法代码控制显隐

### 为什么这么选
- `NSPanel` 是 Apple 专为"工具浮窗"设计的窗口类型
- `.nonactivatingPanel` style mask 让 panel 能 key（接键盘）但 App 不 active（不抢前台 / 不出 Dock 图标）
- `canBecomeKey` 默认对 borderless panel 返回 false，**必须显式覆写**才能拿到键盘焦点

### 踩过的坑
- 最初没覆写 `canBecomeKey`：console 报 warning "calling makeKeyWindow on a window that returned NO from canBecomeKeyWindow"，Esc 收不到
- macOS 26 把 `canBecomeKeyWindow` 改名 `canBecomeKey`（去掉冗余 Window 后缀）——老代码编译时一片红
- 后面**设置窗口**也想用 `NSPanel + .nonactivatingPanel`，结果掉进新坑——这个组合在"主交互窗口"场景下事件路由会进半 key 状态。详见 §6

### 教训
- `canBecomeKey` 覆写是 borderless 浮窗的"出厂必做"
- `.nonactivatingPanel` 是给"绝不抢焦点的工具浮窗"设计的（颜色选择器等）。"主交互窗口"不要用
- AppKit API 改名在新版 macOS 上要警惕。看到 deprecation warning 立刻改

---

## 3. 自动粘贴：`CGEvent` 模拟 ⌘V + 辅助功能权限

### 决策
**用户选中条目后：写 NSPasteboard → 隐藏 popup → 激活之前的 App → 等 80ms → `CGEvent` 发送 ⌘V 键盘事件。**

### 上下文
剪贴板工具的灵魂是"选中即粘"——按 Enter 自动粘贴到刚才操作的输入框，而不是让用户"再切回去手动 ⌘V"。

### 备选
- 只写 NSPasteboard，让用户自己 ⌘V —— 体验差一档
- AX (Accessibility) API 找到 focused element 直接 `setValue` —— 复杂、兼容性差（很多 Web App、Electron App 不暴露 AX 接口）

### 为什么这么选
- `CGEvent` 模拟键盘事件是最通用的方案——任何接受 ⌘V 的 App 都能粘
- 不依赖目标 App 的 AX 实现，原生 / Web / Electron 一视同仁

### 踩过的坑
- **辅助功能权限调试期反复失效**——每次 rebuild，Xcode 把二进制路径换到不同的 DerivedData 子目录，系统 TCC 记录的是旧路径
  - **解决**：在系统设置里手动添加 Clip.app 路径。生产签名构建（Developer ID）不会有这问题
- **时序敏感**：必须先 `previousApp?.activate()` + `Task.sleep(.milliseconds(80))` 才发 `CGEvent`，太快了焦点还在我们 App 上
- **多种"删除键"**：`KeyEquivalent.delete` 实际是 `\u{7F}` (forward delete)，Mac 上 ⌫ 键发的是 `\u{08}` (BS)——`.onKeyPress(.delete)` 完全匹配不上 ⌫。用 `.onKeyPress(characters: CharacterSet)` 才行

### 教训
- **macOS TCC 权限对开发者极其不友好**——签名一变路径一变就重置。生产签名才稳定
- `Task.sleep` 是 Swift Concurrency 替代 `DispatchQueue.asyncAfter` 的现代写法，更易读
- **SwiftUI 常量名容易误导**——`.delete` ≠ "Delete 键"，是字符 DEL。看 SDK 源码确认是好习惯

---

## 4. 剪贴板监听：轮询 `changeCount` + 邻接去重

### 决策
**Timer 每 300ms 轮询 `NSPasteboard.general.changeCount`，变化时读内容。文本用字符串 equality 全局去重，图片用"size + 前 256 字节"邻接去重。**

### 上下文
macOS NSPasteboard **完全没有 push 通知 API**（iOS 有 `UIPasteboardChangedNotification`，macOS 没有）。

### 备选
- 假装有 push 通知 → 没有
- `CGEventTap` 监听 `⌘C` 按键 → 只能抓键盘复制，抓不到右键复制、菜单栏复制、程序化复制
- 私有 API `com.apple.pasteboard.notify.changed` 分发通知 → 不稳，未来可能下架

### 为什么这么选
- 轮询 `changeCount` 是 Maccy / Paste / Raycast 全部用的方案——业界标准
- `changeCount` 是 pasteboardd 维护的递增计数器，读取开销微秒级，300ms 一次 ≈ 0.01% CPU
- "事件驱动 vs 轮询"在这种系统级低成本读取场景下**几乎没差别**

### 图片去重的演进
最初设计：SHA256 hash 当文件名，全局去重，磁盘自然不重复。

**用户反对**："磁盘占用必须给延迟让位。"——SHA256 算 5-500ms，每次复制都卡，这代价不值。

最终方案：
1. **sourcePath 去重**（用户从 Finder 反复复制同一文件 → 路径一致，O(1) 匹配）
2. **邻接指纹去重**（截图等纯数据复制 → 比较 size + 前 256 字节，O(1)）
3. **磁盘上同一图片可能存多份**——可接受的代价

### 教训
- **遇到"理论最优解"时先算 ROI**。SHA256 全局去重是优雅但昂贵的方案，对 100 条历史的小数据集，邻接去重已经覆盖 95% 场景
- 用户的工程直觉值得重视："磁盘占用让位给延迟"这句话定调了整个图片子系统的设计

---

## 5. 图片异步处理：Actor + 后台线程 + UI loading 状态

### 决策
**`ImageProcessor: actor` 处理所有耗时操作（解码、PNG 编码、写盘、缩略图），主线程只负责更新 UI 状态。**

### 上下文
图片解码 / 缩放 / 写盘可能耗时 10-500ms（大图）。同步执行会卡 UI。

### 关键代码模式
```swift
@MainActor func handleImage(data: Data, sourcePath: String?) {
    isProcessingImage = true   // 主线程瞬间触发 UI loading
    Task { @MainActor in
        defer { isProcessingImage = false }
        // await 切到 actor 的后台 executor
        guard let entry = await imageProcessor.process(data: data, sourcePath: sourcePath)
        else { return }
        // 回主线程更新 items
        items.insert(ClipboardItem(kind: .image(entry)), at: pinnedCount)
    }
}
```

### 学到的 Swift Concurrency 关键点
- `actor` 类自动串行化所有方法调用——并发安全免费
- `@MainActor` 标注让编译期就保证"这里必须主线程"
- `await imageProcessor.foo()` 自动切到 actor 的 executor，调用方等待
- `Task { @MainActor in ... }` 显式以主线程为起点，里面的 `await` 不阻塞 UI

### 教训
- **Swift Concurrency 比 GCD 优雅一个数量级**。对从 Rust async/await 过来的人，学习曲线几乎为零
- Actor 替代 lock：你 Rust 里写 `Mutex<T>` 的场景，Swift 写 `actor`

---

## 6. 设置面板的"血泪史"

这一节是整个项目最痛的迭代。**核心教训：UI 模式不要硬上"系统标准模式"**——LSUIElement App + 自定义浮窗的组合是个特殊环境，标准窗口模式在这里全都有副作用。

### 迭代时间线

#### v1：`NSWindow + .titled`
- 直接做，系统标题栏带红黄绿
- 问题：标题栏 chrome 把 SwiftUI 的玻璃效果盖住了。看起来像普通 dark window，不是 Liquid Glass

#### v2：`NSWindow + .borderless + canBecomeKey 覆写`
- 拿掉 chrome，自画 close 按钮
- 问题：4 个角漏出系统阴影（窗口 frame 矩形 + SwiftUI 内容圆角不匹配）

#### v3：`NSPanel + .nonactivatingPanel`（借鉴 popup 的成功）
- 借用 popup 同款架构
- 问题：**事件路由进入"半 key"状态**。打开 settings 后，全局 ⌥+V 静默失效（连日志都没有），状态栏第一次点击没反应，必须先点 panel 本身才解封

#### v4：`NSWindow + setActivationPolicy(.regular) + 关闭时切回 .accessory`
- 暴力激活
- 问题 1：Dock 短暂出现 Clip 图标
- 问题 2：状态栏图标卡在"选中"视觉
- 问题 3：popup 视觉变灰（App 状态污染）
- 问题 4：⌘P / ⌫ 等列表键盘事件也异常

#### v5（最终）：**嵌入 popup，不做独立窗口**
- 新增 `PanelUIState.mode = .list | .settings`
- 同一个 NSPanel，两种内容形态
- 切换：右键菜单触发太脆，挪到 popup header 上的齿轮按钮
- 结果：**所有问题一次性消失**

### 教训
- **"我们的 settings 没必要是独立窗口"** 这个判断应该 v1 就做出来
- **被"系统约定"绑架是常见反模式**。"标准 macOS App 应该有独立设置窗口"——但 Maccy、Spotlight、Raycast 也都没遵守这条
- **架构选错时，每次"修一个症状"会引爆下一个症状**——v3 修 v2 的角，v4 修 v3 的焦点，v5 才发现根问题不在窗口上，在"应不应该有独立窗口"上
- **退一步看本质，比硬修一线问题贵得多但值得**

---

## 7. About 窗口（同样的坑，被避开了）

### 决策
**右键菜单"关于 Clip"暂时不做**，相关代码以注释保留。

### 上下文
做完设置面板的 v5 后，做 About 窗口，沿用 `NSApp.orderFrontStandardAboutPanel()` 系统标准 API。结果——

### 踩过的坑
"NSMenu action → 新窗口"过渡 bug **同款再现**：菜单项 click → `orderFrontStandardAboutPanel` 触发 → About 窗口进入半 key / 半激活的怪状态。

### 教训
- **特定的事件链组合在 macOS 上有时序 bug**："NSMenu action 回调里弹任何独立窗口"几乎一定踩雷
- **早识别 pattern**：一个症状反复出现说明背后是同一个底层 bug
- **绕开 vs 修复**：绕开（不走那条路径）通常比修复（chai 解 macOS 内部时序）便宜

### 将来怎么做
和 settings 一样：嵌进 popup，加一个 `.about` 模式。**等需要时再做**。

---

## 8. Liquid Glass：macOS 26 的 `.glassEffect`

### 决策
**用 SwiftUI macOS 26 新 API `.glassEffect(.clear.tint(.black.opacity(0.95)), in: RoundedRectangle(cornerRadius: 14))`。**

### 替代方案
- `NSVisualEffectView`（AppKit 老 API）—— 视觉略不如 Liquid Glass，但稳
- `.background(.ultraThinMaterial, ...)` —— macOS 26 上也走 Liquid Glass 渲染管线，但和 `.glassEffect` 视觉略不同

### 踩过的坑
**任何"真模糊"渲染都会触发一次 `_NSDetectedLayoutRecursion` warning**：
- `.glassEffect()` ✗
- `.background(.ultraThinMaterial)` ✗
- `NSVisualEffectView` ✗
- 纯色背景 ✓（无 warning，但视觉不可接受）

实验确认这是 SwiftUI + NSHostingController + 真模糊渲染管线的 **Apple 自家 bug**。warning 只打印一次，不影响功能，未来 Apple 应该会修。

### 教训
- **接受不可解的小瑕疵**。和"花两天调 Apple 内部时序"比起来，一行 warning 是性价比最高的选择
- **写诊断注释**：代码里详细说明"为什么这个 warning 无害"，未来回看 + 招聘看代码的人不会浪费时间排查

---

## 9. KeyboardShortcuts 库的"暗坑"

### 决策
**用 Sindre Sorhus 的 [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) 库注册全局快捷键，但 Recorder 控件按需挂载（不能常驻）。**

### 踩过的坑
最初把 `KeyboardShortcuts.Recorder` 直接挂在设置表单里。结果：**一打开设置，全局 ⌥+V 完全失效，连日志都没有**。

调试半天发现：**Recorder 渲染到屏幕上时，库内部自动把 Carbon HotKey 暂停了**（避免用户录制时旧快捷键触发干扰）。

### 修复
按需挂载：默认显示"⌥V"只读字串 + "修改"按钮，点击才挂载 Recorder。录完点"完成"销毁 Recorder，hotkey 恢复。

```swift
if isRecordingShortcut {
    KeyboardShortcuts.Recorder("...", name: .toggleClip)  // 录制时挂
} else {
    Text("⌥V") + Button("修改")  // 平时显示
}
```

### 教训
- **第三方控件的副作用要看清**——挂在 view tree 的代价不止是渲染
- 这种"看似无害的视图导致系统行为改变"是 SwiftUI 生态的常见暗坑
- 思路：**stateful 第三方控件（Recorder、Camera 预览、Audio 录制）都按需挂载**

---

## 10. 持久化：JSON + 外部图片文件

### 决策
**JSON 存历史元数据（含缩略图 base64 内联），原图存 `~/.../Clip/images/<uuid>.png` 单独文件。**

### 上下文
SQLite 工程量过大（schema + 库依赖），UserDefaults 不适合数组数据，Property List 不如 JSON 可读。

### 关键决策点
- **缩略图内联 vs 外部**：内联（40×40 PNG ~10KB × 100 张 = 1MB）启动加载快 → 内联
- **原图内联 vs 外部**：内联（500KB × 100 张 = 50MB JSON）每次保存重写 50MB → 外部
- **文件命名**：最初想用 SHA256 hash（自然去重），改成 UUID（延迟优先）。**详见 §4**

### Codable 向后兼容
加 `isPinned` 字段时，老 JSON 没有这个 key。用自定义 `init(from decoder:)` 兜底：
```swift
init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try c.decode(UUID.self, forKey: .id)
    // ...
    self.isPinned = (try? c.decode(Bool.self, forKey: .isPinned)) ?? false
}
```

### 教训
- **持久化的 schema 演进早做准备**——Codable 自动合成的 decoder 对缺失字段会 throw，必须自定义
- "二进制内联到 JSON" 看似简单但启动慢，**大文件外部存储 + 元数据引用**是经典模式
- **沙盒 App 的数据路径**：`~/Library/Containers/<bundleID>/Data/Library/Application Support/<AppName>/` 而非常规 `~/Library/Application Support/<AppName>/`——`FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)` 自动重定向

---

## 11. 置顶功能的迭代

### 三轮设计
1. **v1**：垂直列表里加 `isPinned` 字段，置顶项排前面，pin.fill 图标
   - 问题：5 个置顶吃掉一半 panel 高度
2. **v2**：横向排列 + 自适应宽度（`LazyVGrid` 列数 = pinned.count），最多 5 个
   - 问题：5 个 chip 每个 64pt 太窄；硬编码上限不灵活
3. **v3（最终）**：水平 ScrollView + 固定宽度 chip + UserDefaults 可配上限
   - 用户可调上限 1-20
   - 多了就横向滚动
   - ⌘1-9 键盘快捷键访问前 9 个

### Toast 失败的尝试
v3 期间想做"置顶已满"toast 提示。试了两种实现（`.transition` + 条件渲染、`.opacity` + 始终渲染），**都没显示出来**。怀疑是 `.glassEffect` 容器内 overlay 渲染管线的 bug，没深究。

最终绕开：用户自己配上限，超额时静默失败（console 有 log）。**让用户掌控** > **让系统弹窗教育用户**。

### 教训
- **UX 迭代时机要看实际使用反馈**。我们以为垂直没问题，用户用了才发现"5 个就吃掉一半空间"
- **绕不开的 SwiftUI 渲染 bug 不要硬刚**——toast 不显示这个 case 应该立刻寻替代方案，而不是反复调 transition
- **UI 决策和数据决策分开**：上限是数据层（PasteboardWatcher），布局是 UI 层（ContentView）。改 UI 不影响数据，改数据不破坏 UI

---

## 12. SwiftUI 的几个常踩 API 陷阱

### `.onKeyPress` 的多 overload 陷阱
```swift
.onKeyPress(.delete) { }                                    // 闭包无参数
.onKeyPress(keys: [.delete]) { press in }                   // 带 KeyPress
.onKeyPress(characters: CharSet) { press in }               // 带 KeyPress
```
单 key 版本闭包不带参数 → 拿不到 modifiers。要查 `press.modifiers.contains(.command)` 必须用后两种 overload。

### `KeyEquivalent.delete` 不是 ⌫
`.delete` = `\u{7F}` = forward delete。Mac 上 ⌫ 键发 `\u{8}` (BS)。两个完全不同的字符。

### `.onChange(of: array.map(\.id))` 触发 layout 递归
每次 body 求值都创建新 `[UUID]` 数组，SwiftUI 比较时可能误判变化 → 重渲染循环。改用稳定的 sentinel state（如 `scrollPing: Int`）代替。

### `@State` 在 init 里赋值
```swift
init(value: Int) {
    _myState = State(initialValue: value)  // 底层访问语法
}
```
直接 `myState = value` 报错。前置下划线是 `@State` 包装器的 projectedValue。

### `Color.tertiary` 不存在
`tertiary` 是 `HierarchicalShapeStyle`，只能用在 `.foregroundStyle(.tertiary)`。`Color` 类型要用 `.primary.opacity(0.4)` 近似。

---

## 13. macOS 系统模型的几个关键概念

### 三个独立维度
| 维度 | 取值 | 影响 |
|---|---|---|
| App activation | active / inactive | 菜单栏归谁、frontmost App 是谁 |
| Activation policy | .regular / .accessory / .prohibited | Dock 是否显示、能否 active |
| Window key/main | key window / main window | 键盘事件路由 |

**这三个维度看似相关实则独立**。我们栽过的坑大多源于把它们当一回事：
- 给 LSUIElement App（policy = .accessory）调 `setActivationPolicy(.regular)` → Dock 出图标
- 把 panel `makeKey` → App 不一定 active
- App active → window 不一定 key（多窗口时）

### LSUIElement = YES 的隐含语义
- App 启动时 `activation policy = .accessory`
- 永不在 Dock 显示
- 永不在 ⌘+Tab 切换列表
- 没有 system menu bar（即 File / Edit / View 那一栏）
- 但**可以有 key window**，可以接收键盘事件

### `previousApp` 跟踪模式
菜单栏 App 弹窗口时，要记下"我打开前的前台 App 是谁"，关闭时还焦点回去。`NSWorkspace.shared.frontmostApplication` 是关键 API。

---

## 14. 从 Rust 视角看 Swift

### 等价物对照
| Rust | Swift |
|---|---|
| `Option<T>` | `T?` (Optional) |
| `Result<T, E>` | `throws` + do-try-catch |
| `&self` / `&mut self` | `mutating func` 区分 |
| `trait` | `protocol` |
| `impl` | `extension` |
| `derive(Serialize, Deserialize)` | `: Codable`（自动合成）|
| `derive(Eq, Hash)` | `: Hashable`（自动合成）|
| `Send + Sync` | `actor` / `@MainActor` |
| `Mutex<T>` | `actor` |
| `Arc<T>` | `class`（引用类型默认 ARC）|
| `Box<dyn Trait>` | `any Protocol` |
| `match` | `switch` with associated values |
| `?` 操作符 | `try?` / `try!` |

### 思维转变
- Rust：编译期强制，所有权 + 借用，零成本抽象
- Swift：编译期帮你 + 运行期 ARC 兜底，开发速度优先

**对剪贴板这种小工具，Swift 的开发速度优势压倒一切**。Rust 的所有权检查在 GUI 状态管理场景反而是摩擦。

### 想念 Rust 的几个点
- `cargo check` 比 Xcode build 快几倍
- `cargo doc` 比 Xcode 文档浏览方便
- Rust 的错误消息比 Swift 的 `unable to infer type` 友好

### Swift 比 Rust 爽的几个点
- `Codable` 自动合成 = 把 serde 内化进语言
- `@Observable` 自动追踪 = 没有 Rx 那种"信号烟雾"
- Property wrapper 是真好用（`@State` / `@Binding` / `@AppStorage`）
- 不写 lifetime

---

## 15. 经验法则

### 决策原则
- **早识别"想要标准 macOS 模式 vs 实际可行的特殊场景"的冲突**
- **副作用大的 API 当核武器看待**（`setActivationPolicy`、TCC 权限请求、字体注册等）
- **第三方 stateful 控件按需挂载**
- **遇到看似不可解的 SwiftUI 渲染 bug，绕开比修便宜**
- **磁盘空间是廉价资源，延迟是宝贵资源**——这个 trade-off 在任何工具类 App 都适用

### 调试原则
- **加日志 > 猜测**。我猜错三次 ≈ 加一行 print 解决问题
- **"问题反复出现"说明根因在更深层**，不要继续修表面
- **看 SDK 源码 / 头文件**比看 Apple 文档常常更准确
- **复现条件最小化**：把"点 5 下才出错"压缩到"点 1 下出错"再调

### UX 决策原则
- **小窗工具的关键词是密度**。横向陈列 > 垂直列表
- **用户自定义 > 系统提示**。让用户调上限 > 弹 toast 告诉用户"满了"
- **可见的失败 > 不可见的成功**。一个动作没生效，用户能从视觉看出来，比给一个 toast 提示更好

---

## 16. 未做但应该做的（备忘）

- 单元测试（PasteboardWatcher 的 evict 逻辑、置顶切换、Codable 向后兼容）
- 集成测试（CGEvent 模拟 + 真实 App 粘贴）—— 难以自动化，但值得尝试
- 性能 profiling（用 Instruments 看 SwiftUI 渲染开销）
- 国际化（目前所有 UI 文字都中文硬编码，要支持英文需要 Localizable.strings）
- About 窗口（嵌入 popup，做 `.about` 模式）
- 签名 + 公证 + GitHub Release 自动构建
- 删除超额置顶时的 evict 策略可以更智能（现在直接 unpin 最末，更好的策略是 LRU）
- "刚刚 / X 分钟前" 时间显示不自动刷新——要么改 `Text(date, style: .relative)`（系统自动刷新），要么用 Timer 主动 invalidate

---

## 17. 给后来者的话

如果你和我一样是 Rust 背景想吃透 Swift：

1. **找一个有真实需求的小项目动手**，比看任何教程都有效
2. **预算时间的 50% 给系统 API 而不是语言**——Swift 本身 1 周能熟，macOS 系统 API 1 个月都不够
3. **接受"看起来该工作但不工作"的不爽**。AppKit 30 年沉淀 + SwiftUI 5 年新生 + macOS 26 新 API 三者的边界处全是雷
4. **不要追求"标准"**，追求"能用且稳"。macOS App 写到第 50 个的人才有资格写"标准"

---

*Written by xumj, with Claude as pair programmer.*
*2026-05*

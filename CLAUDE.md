# CLAUDE.md

> Claude Code 在这个仓库工作时的上下文。给未来的我和未来的 Claude 看。

## 项目是什么

**Clip** —— 一个 macOS 26 (Tahoe) 的剪贴板管理器。菜单栏 App，全局快捷键 `⌥V` 唤出 Spotlight 风格的浮窗，列表展示文本/图片历史，回车自动粘贴到原 App。

技术栈：Swift 6 + SwiftUI + AppKit + Swift Concurrency。

## 怎么跑

- Xcode 打开 `clip.xcodeproj`，⌘R
- 首次按 Enter 粘贴时系统会弹"辅助功能权限"对话框，到 系统设置 → 隐私与安全性 → 辅助功能 里加入 clip
- 命令行构建：`xcodebuild -project clip.xcodeproj -scheme clip -configuration Debug build`

## 工程结构

Xcode 项目用的是 **`PBXFileSystemSynchronizedRootGroup`** —— `clip/` 下任何文件夹/文件 Xcode 自动收录，**不需要手动维护 `.pbxproj`**。新增/移动文件只动磁盘就行（`Info.plist` 是 membership exception，已配置）。

按"层"组织目录（依赖方向：App → Window → Views → Services → Models）：

```
clip/
├── App/         入口 + 生命周期
│   ├── clipApp.swift           SwiftUI @main，桥接 AppDelegate
│   ├── AppDelegate.swift       AppKit 生命周期，启动 watcher + 注册全局快捷键
│   └── GlobalShortcuts.swift   KeyboardShortcuts 库的快捷键命名
├── Models/      纯数据
│   └── ClipboardItem.swift     条目模型 + Kind 枚举 (.text / .image) + ImageEntry
├── Services/    业务逻辑（不碰 UI）
│   ├── PasteboardWatcher.swift Pasteboard 轮询、去重、持久化、容量管理（核心 482 行）
│   ├── ImageProcessor.swift    actor，图片解码/编码/写盘/缩略图（后台线程）
│   └── Paster.swift            CGEvent 模拟 ⌘V + 辅助功能权限检查
├── Window/      AppKit 浮窗基础设施
│   ├── FloatingPanel.swift     NSPanel 子类，覆写 canBecomeKey
│   ├── PanelUIState.swift      共享 list/settings 模式状态（@Observable）
│   └── StatusBarController.swift  菜单栏图标 + popup + 鼠标定位 + 粘贴流程
├── Views/       SwiftUI 视图
│   ├── ContentView.swift       popup 根视图 + 键盘事件路由
│   ├── ItemRow.swift           列表单行（文本/图片双类型渲染）
│   ├── ProcessingRow.swift     图片处理中占位条
│   ├── PinnedChip.swift        置顶区水平滚动的 chip
│   └── SettingsView.swift      偏好设置（嵌在 popup 里，不是独立窗口）
├── Extensions/
│   └── Date+RelativeShort.swift  "刚刚 / N 分钟前" 时间格式化
├── Assets.xcassets/
└── Info.plist                  LSUIElement = YES（菜单栏 App，无 Dock 图标）
```

## 架构关键决定（重要踩坑）

完整版见 `RETROSPECTIVE.md` 和 `README.md`。这里只列开发时最容易踩的几个：

### 1. 设置 UI 嵌在 popup 里，不要独立窗口
LSUIElement App + 独立 NSWindow/NSPanel 会撞一连串焦点问题（`canBecomeKey`、`.regular` 激活策略残留 Dock、半 key 状态）。当前实现：`SettingsView` 是 `ContentView` 的另一种"模式"，靠 `PanelUIState.mode` 切换。**Spotlight、Raycast 也不用独立窗口**——别为"和系统一致"硬上。

### 2. `KeyboardShortcuts.Recorder` 按需挂载
Recorder 控件渲染时会**自动暂停全局 hotkey**（库的内部行为）。如果常驻 settings 表单里 → ⌥V 一进设置就废。**正解**：默认只读显示当前快捷键 + "修改"按钮，点修改才挂 Recorder，录完销毁。

### 3. 图片不内联 JSON
原图二进制存 `~/Library/Application Support/Clip/images/<uuid>.png`，JSON 里只存元数据 + 40×40 缩略图。100 张图 × 500KB = 50MB JSON 会卡启动。

### 4. 邻接去重，不要全局 hash
全局 SHA256 同步 5-500ms 不可接受。当前只对"上一次"做 size + 前 256 字节比较，覆盖"误按两次 ⌘C"99% 场景。同一图复制多次会产生多份文件——这是用户明确同意的取舍（磁盘代价 < 响应延迟）。

### 5. `FloatingPanel.canBecomeKey = true` 必须覆写
默认 borderless NSPanel `canBecomeKey` 返回 NO，不覆写就收不到键盘事件、`makeKeyAndOrderFront` 抛 warning。

### 6. `_NSDetectedLayoutRecursion` 启动 warning 可以忽略
SwiftUI + NSHostingController + 任何"真模糊"渲染（`.glassEffect`、NSVisualEffectView）都会触发，Apple 没修，只打一次，不影响功能。**不要追这个**。

## 持久化文件位置

```
~/Library/Application Support/Clip/
├── history.json          所有条目元数据（含缩略图 base64）
└── images/               原图 PNG，<uuid>.png
```

UserDefaults 存配置：`maxItems` / `maxImages` / `maxPinned` / KeyboardShortcuts 快捷键。

## 改代码时的注意

- **加新文件**：放对应层目录就行，Xcode 自动收录
- **新的 SwiftUI 子视图**：放 `Views/`，独立成文件（参考 ItemRow / ProcessingRow 的拆法）
- **加全局快捷键**：在 `App/GlobalShortcuts.swift` 里加 `KeyboardShortcuts.Name`，再到 `AppDelegate.applicationDidFinishLaunching` 注册
- **新的剪贴板内容类型**：扩展 `ClipboardItem.Kind` 枚举（编译器会强制把 switch 全部更新一遍——这是用 enum 的好处）
- **改 `Info.plist`**：它在 membership exception 里，不要乱动 plist 路径

## 常用命令

```bash
# 编译验证
xcodebuild -project clip.xcodeproj -scheme clip -configuration Debug build -quiet

# 行数统计（看哪个文件膨胀了）
find clip -name "*.swift" -type f | xargs wc -l | sort -n

# 清干净 DerivedData（辅助功能权限错乱时偶尔需要）
rm -rf ~/Library/Developer/Xcode/DerivedData/clip-*
```

## 相关文档

- `README.md` —— 对外说明 + 完整设计决定与踩坑
- `RETROSPECTIVE.md` —— 项目复盘（11 条决定的来龙去脉）

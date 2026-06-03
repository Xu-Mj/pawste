# Clip

[![Build](https://github.com/Xu-Mj/clip/actions/workflows/build.yml/badge.svg)](https://github.com/Xu-Mj/clip/actions/workflows/build.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

> 一个 Spotlight 风格的 macOS 剪贴板管理器。菜单栏常驻，全局快捷键 `⌥V` 唤出浮窗，文本和图片历史一键回填到当前 App。

为 macOS 26 (Tahoe) 的 Liquid Glass 设计，SwiftUI + AppKit 混合实现。

---

## 功能

- **全局唤起** —— 任意 App 内按 `⌥V` 即刻弹出，浮窗出现在鼠标附近，多显示器自适应
- **文本 + 图片** —— 自动记录两类内容；图片支持 PNG / JPEG / TIFF / GIF / BMP / HEIC，统一转 PNG 存储
- **回车即粘贴** —— 选中条目按 `Enter`，自动粘贴到唤起前的 App（模拟 ⌘V，无需手动粘）
- **快速搜索** —— `⌘F` 聚焦搜索框，实时过滤文本与图片
- **置顶常用** —— `⌘P` 把条目钉到顶部置顶区，不受容量上限淘汰；`⌘1`–`⌘9` 直接粘贴置顶项
- **数字快捷** —— `1`–`9` 直接粘贴列表对应位置的条目
- **键盘全覆盖** —— `↑↓` 导航、`Enter` 粘贴、`⌫` 删除，全程不碰鼠标
- **本地优先** —— 历史存在本地，重启不丢；图片单独落盘按需加载，启动飞快
- **容量可配** —— 文本、图片、置顶各自独立上限，可在偏好设置调整
- **开机自启** —— 一键开关
- **轻量** —— 菜单栏常驻，待机几乎零 CPU

---

## 系统要求

| | |
|---|---|
| 操作系统 | **macOS 26 (Tahoe) 或更高** |
| 构建工具 | Xcode 26+ |

> ⚠️ Clip 用了 macOS 26 才有的 Liquid Glass（`.glassEffect`）等 API，**无法在更低版本的 macOS 上构建或运行**。

---

## 安装

目前还没有签名 / 公证的预编译版本，请从源码构建：

```bash
git clone https://github.com/Xu-Mj/clip.git
cd clip
open clip.xcodeproj
# 在 Xcode 里按 ⌘R 运行
```

或者命令行构建：

```bash
xcodebuild -project clip.xcodeproj -scheme clip -configuration Release build
```

### 首次使用：授予辅助功能权限

Clip 通过模拟 ⌘V 把内容粘回原 App，这需要**辅助功能**权限。第一次按 `Enter` 粘贴时系统会弹出对话框，按提示前往：

**系统设置 → 隐私与安全性 → 辅助功能 → 勾选 Clip**

---

## 使用

按 `⌥V` 唤出浮窗，输入即搜索，方向键选择，回车粘贴。

### 快捷键

| 快捷键 | 行为 |
|---|---|
| `⌥V` | 唤出 / 隐藏浮窗 |
| `↑` `↓` | 在列表中移动选择 |
| `Enter` | 粘贴选中条目到原 App |
| `1`–`9` | 直接粘贴列表对应位置的条目 |
| `⌘1`–`⌘9` | 直接粘贴置顶区对应位置的条目 |
| `⌘F` | 聚焦搜索框 |
| `⌘P` | 置顶 / 取消置顶选中条目 |
| `⌫` | 删除选中条目 |
| `Esc` | 清除搜索 → 退出搜索 → 关闭浮窗（逐级） |
| 右键状态栏 | 关于 / 退出 |

默认快捷键 `⌥V` 可在偏好设置里自定义。

---

## 架构

按依赖方向分层组织（`App → Window → Views → Services → Models`）：

```
clip/
├── App/         入口与生命周期（@main、AppDelegate、全局快捷键注册）
├── Models/      纯数据模型（ClipboardItem）
├── Services/    业务逻辑（剪贴板监听、图片处理、粘贴注入）
├── Window/      AppKit 浮窗基础设施（FloatingPanel、StatusBarController）
├── Views/       SwiftUI 视图（列表、行、置顶 chip、设置、关于）
└── Extensions/  小工具扩展
```

几个核心模块：

| 模块 | 职责 |
|---|---|
| `PasteboardWatcher` | 轮询 `NSPasteboard`，去重、持久化、容量淘汰 |
| `ImageProcessor` | `actor` —— 图片解码 / 编码 / 写盘 / 缩略图，全在后台线程 |
| `Paster` | `CGEvent` 模拟 ⌘V + 辅助功能权限检查 |
| `StatusBarController` | 菜单栏图标 + 浮窗显隐 + 鼠标定位 + 粘贴流程编排 |
| `ContentView` | 浮窗根视图，按模式渲染列表 / 设置 / 关于，路由键盘事件 |

> 想了解每个技术选型背后的取舍、踩过的坑和教训，见 **[RETROSPECTIVE.md](RETROSPECTIVE.md)**（完整项目复盘）。仓库协作约定见 **[CLAUDE.md](CLAUDE.md)**。

---

## 技术栈

- **Swift** + **SwiftUI**（UI）+ **AppKit**（窗口、菜单栏、事件）
- **Swift Concurrency**（`async/await`、`actor`、`@MainActor`）
- **`@Observable`** 宏做状态管理
- **`SMAppService`** 实现开机自启
- **Liquid Glass**（`.glassEffect`，macOS 26+）
- **[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)** by Sindre Sorhus —— 全局快捷键注册与录制

---

## 设计取舍（速览）

几个对体验影响最大的决定，详细来龙去脉见 [RETROSPECTIVE.md](RETROSPECTIVE.md)：

- **浮窗用 `NSPanel + .nonactivatingPanel`**，能拿键盘焦点但不激活整个 App —— 菜单栏工具弹"浮岛"的标准配方。
- **设置 / 关于都嵌进浮窗**，不开独立窗口 —— 避开 LSUIElement App 下独立窗口的一连串焦点 / Dock / 半 key 状态问题。
- **轮询 `changeCount` + 邻接去重** —— macOS 没有剪贴板变更通知 API，只能轮询；去重只跟"上一次"比，把响应延迟压到最低。
- **图片不内联进 JSON** —— 原图单独落盘，历史文件只存元数据 + 缩略图，启动加载飞快。

---

## 已知问题

- 启动时控制台会打印一次 `_NSDetectedLayoutRecursion` 警告 —— SwiftUI + 真模糊渲染管线的系统级 bug，只出现一次，不影响功能。
- 调试构建偶尔需要重新授予辅助功能权限（DerivedData 路径变化导致）—— 构建 Release 版装到 `/Applications` 可避免。

---

## 路线图

- [ ] 应用图标精修（当前为占位）
- [ ] 代码签名 + 公证 + 预编译版本分发
- [ ] 截图 / 演示动图
- [ ] 富文本 / 文件类型支持

已完成：搜索、置顶、键盘删除、关于页、GitHub Actions 自动构建。

---

## 贡献

欢迎 Issue 和 PR。提 PR 前请确保 `xcodebuild ... build` 能通过（CI 也会自动校验）。

---

## 许可

[MIT](LICENSE)

致谢 [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)。

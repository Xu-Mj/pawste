import Foundation

// 轻量调试日志：只在 DEBUG 构建输出，发布版完全静音
//
// @autoclosure：发布版里连字符串都不构造（参数表达式不求值），零开销
// 用法和 print 一样：log("📋 启动，容量 \(maxItems)")
//
// 为什么不直接用 os.Logger：项目日志都是带 emoji 的开发期调试信息，
// 用 #if DEBUG 的 print 风格保持一致、零迁移成本；发布版静音是核心诉求
// nonisolated：项目设了 SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor，
// 全局函数默认会变 @MainActor；标 nonisolated 才能从 actor / 后台线程调用
// （print 本身任何线程都安全）
@inline(__always)
nonisolated func log(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

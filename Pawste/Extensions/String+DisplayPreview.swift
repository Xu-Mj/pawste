import Foundation

// 把多行文本压成"单行预览"用的展示字符串
//
// 用途：列表行 / 置顶 chip 在窄空间里只能显示一行，但又不能让"a\n\n\n" 这种
// 单字 + 多换行的内容看起来像只复制了一个字。把换行符替换成可见符号 ↵，
// 一眼能看出"这条还有更多内容"。
//
// 原始内容（item.kind 里的 String）不变，粘贴出去的还是带真实换行的完整文本。
//
// 处理顺序：
//   1. 去前后空白和换行（避免 ↵↵hello 这种开头一堆符号的视觉噪音）
//   2. 截前 200 字符——预览只渲染一行（lineLimit(1)），360pt 宽的行肉眼可见的就
//      开头几十个字符，没必要对几 MB 的大文本全量做替换
//   3. CRLF (\r\n) 先于 \n / \r 替换，否则 Windows 复制来的会出现两个 ↵
extension String {
    var displayPreview: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(200)
            .replacingOccurrences(of: "\r\n", with: "↵")
            .replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\r", with: "↵")
    }
}

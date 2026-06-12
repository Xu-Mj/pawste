import Foundation

// "刚刚 / N 分钟前 / N 小时前 / N 天前 / MM-dd"
//
// 列表里每条历史显示时间用的格式
// 系统 RelativeDateTimeFormatter 输出过于啰嗦（"5 minutes ago" → "5 分钟前" 但带空格、变体多）
// 自己写一版更紧凑、风格统一
extension Date {
    // 兜底格式器缓存：DateFormatter 构造是毫秒级开销，而 relativeShort 列表每行渲染都会调
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()

    private static let yearMonthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var relativeShort: String {
        let interval = Date().timeIntervalSince(self)
        switch interval {
        case ..<60:
            return "刚刚"
        case ..<3600:
            return "\(Int(interval / 60)) 分钟前"
        case ..<86400:
            return "\(Int(interval / 3600)) 小时前"
        case ..<(86400 * 7):
            return "\(Int(interval / 86400)) 天前"
        default:
            // 跨年的老条目带上年份（置顶项可以存活很多年，"06-11"会有歧义）
            let sameYear = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
            return (sameYear ? Self.monthDayFormatter : Self.yearMonthDayFormatter)
                .string(from: self)
        }
    }
}

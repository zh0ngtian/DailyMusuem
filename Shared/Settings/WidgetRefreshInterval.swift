import Foundation

enum WidgetRefreshInterval: Int, CaseIterable, Identifiable {
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case sixHours = 360
    case twelveHours = 720
    case oneDay = 1440

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .fifteenMinutes: return "15 分钟"
        case .thirtyMinutes: return "30 分钟"
        case .oneHour: return "1 小时"
        case .sixHours: return "6 小时"
        case .twelveHours: return "12 小时"
        case .oneDay: return "24 小时"
        }
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue * 60)
    }
}


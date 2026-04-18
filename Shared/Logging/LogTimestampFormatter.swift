import Foundation

enum LogTimestampFormatter {
    private static let formattingLocale = Locale(identifier: "en_US_POSIX")

    static func requestLogTimestamp(from date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let components = dateComponents(for: date, timeZone: timeZone)
        return String(
            format: "%02d-%02d %02d:%02d:%02d.%06d",
            locale: formattingLocale,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            microseconds(from: components.nanosecond)
        )
    }

    static func feedLogTimestamp(from date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let components = dateComponents(for: date, timeZone: timeZone)
        return String(
            format: "%02d:%02d:%02d.%06d",
            locale: formattingLocale,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            microseconds(from: components.nanosecond)
        )
    }

    private static func dateComponents(for date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = formattingLocale
        calendar.timeZone = timeZone
        return calendar.dateComponents(
            [.month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
    }

    private static func microseconds(from nanosecond: Int?) -> Int {
        let value = (nanosecond ?? 0) / 1_000
        return min(max(value, 0), 999_999)
    }
}

import Foundation

enum LogTimestampFormatter {
    private static let formattingLocale = Locale(identifier: "en_US_POSIX")

    static func requestLogTimestamp(from date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let (components, milliseconds) = normalizedTimeParts(for: date, timeZone: timeZone)
        return String(
            format: "%02d-%02d %02d:%02d:%02d.%03d",
            locale: formattingLocale,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            milliseconds
        )
    }

    static func feedLogTimestamp(from date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let (components, milliseconds) = normalizedTimeParts(for: date, timeZone: timeZone)
        return String(
            format: "%02d:%02d:%02d.%03d",
            locale: formattingLocale,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            milliseconds
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

    private static func normalizedTimeParts(for date: Date, timeZone: TimeZone) -> (DateComponents, Int) {
        let components = dateComponents(for: date, timeZone: timeZone)
        let roundedMilliseconds = milliseconds(from: components.nanosecond)
        guard roundedMilliseconds == 1_000 else {
            return (components, roundedMilliseconds)
        }

        let carriedDate = date.addingTimeInterval(1)
        return (dateComponents(for: carriedDate, timeZone: timeZone), 0)
    }

    private static func milliseconds(from nanosecond: Int?) -> Int {
        let value = Int((Double(nanosecond ?? 0) / 1_000_000).rounded())
        return min(max(value, 0), 1_000)
    }
}

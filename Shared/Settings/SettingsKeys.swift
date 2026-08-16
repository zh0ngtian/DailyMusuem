import Foundation

enum SettingsKeys {
    static let appGroupID = "group.tech.zh0ngtian.MuseumMuse"
    static let widgetKind = "DailyMuseumWidget"
    static let feedPreferences = "feed.preferences.v2"
    static let feedDisplayModePrefix = "feed.displayMode."
    static let widgetRefreshIntervalHours = "widget.refreshIntervalHours"
    static let widgetAutoRefreshStartMinutes = "widget.autoRefreshStartMinutes"
    static let widgetAutoRefreshEndMinutes = "widget.autoRefreshEndMinutes"
    static let artworkDetailFontScaleStep = "artworkDetail.fontScaleStep"
    static let requestLogAccessUnlocked = "requestLog.accessUnlocked"
    static let museumDisplayOrder = "museum.displayOrder"
    static let favoritesArtworks = "favorites.artworks"

}

struct FeedPreferences: Codable, Equatable, Sendable {
    var museums: [String: MuseumFeedPreference] = [:]
}

struct MuseumFeedPreference: Codable, Equatable, Sendable {
    var selectedSourceKey: String?
    var selectedCategoryIDsBySource: [String: [String]] = [:]
}

enum ArtworkDetailFontScale {
    static let minimumStep = -2
    static let maximumStep = 3
    static let defaultStep = 0

    static func storedStep(in defaults: UserDefaults) -> Int {
        guard let number = defaults.object(forKey: SettingsKeys.artworkDetailFontScaleStep) as? NSNumber else {
            return defaultStep
        }
        return clampedStep(number.intValue)
    }

    static func clampedStep(_ step: Int) -> Int {
        min(max(step, minimumStep), maximumStep)
    }
}

enum WidgetRefreshInterval: Int, CaseIterable, Identifiable, Equatable, Hashable {
    case off = 0
    case oneHour = 1
    case threeHours = 3
    case sixHours = 6
    case twelveHours = 12
    case twentyFourHours = 24

    static let defaultValue: WidgetRefreshInterval = .twentyFourHours

    var id: Int { rawValue }

    var isEnabled: Bool {
        self != .off
    }

    var timeInterval: TimeInterval {
        TimeInterval(rawValue) * 60 * 60
    }

    var displayName: String {
        if self == .off {
            return "关闭"
        }
        return "\(rawValue)小时"
    }

    static func storedValue(in defaults: UserDefaults) -> WidgetRefreshInterval {
        guard let storedHours = defaults.object(forKey: SettingsKeys.widgetRefreshIntervalHours) as? NSNumber else {
            return defaultValue
        }
        return WidgetRefreshInterval(rawValue: storedHours.intValue) ?? defaultValue
    }
}

struct WidgetAutoRefreshWindow: Equatable, Hashable {
    static let minimumMinutes = 0
    static let maximumMinutes = 23 * 60
    static let selectableMinutes = Array(stride(from: minimumMinutes, through: maximumMinutes, by: 60))
    static let defaultValue = WidgetAutoRefreshWindow(
        uncheckedStartMinutes: 0,
        uncheckedEndMinutes: maximumMinutes
    )

    let startMinutes: Int
    let endMinutes: Int

    init(startMinutes: Int, endMinutes: Int) {
        let normalized = Self.normalized(startMinutes: startMinutes, endMinutes: endMinutes)
        self = normalized
    }

    private init(uncheckedStartMinutes: Int, uncheckedEndMinutes: Int) {
        startMinutes = uncheckedStartMinutes
        endMinutes = uncheckedEndMinutes
    }

    static func normalized(startMinutes: Int, endMinutes: Int) -> WidgetAutoRefreshWindow {
        let normalizedStart = clamp(minutes: startMinutes)
        let normalizedEnd = max(normalizedStart, clamp(minutes: endMinutes))
        return WidgetAutoRefreshWindow(
            uncheckedStartMinutes: normalizedStart,
            uncheckedEndMinutes: normalizedEnd
        )
    }

    static func storedValue(in defaults: UserDefaults) -> WidgetAutoRefreshWindow {
        let startMinutes = (defaults.object(forKey: SettingsKeys.widgetAutoRefreshStartMinutes) as? NSNumber)?
            .intValue ?? defaultValue.startMinutes
        let endMinutes = (defaults.object(forKey: SettingsKeys.widgetAutoRefreshEndMinutes) as? NSNumber)?
            .intValue ?? defaultValue.endMinutes
        return normalized(startMinutes: startMinutes, endMinutes: endMinutes)
    }

    static func clamp(minutes: Int) -> Int {
        let clamped = min(max(minutes, minimumMinutes), maximumMinutes)
        return (clamped / 60) * 60
    }

    static func minutesSinceStartOfDay(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return clamp(minutes: hour * 60 + minute)
    }

    static func date(
        for minutes: Int,
        referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.startOfDay(for: referenceDate)
            .addingTimeInterval(TimeInterval(clamp(minutes: minutes) * 60))
    }

    static func displayText(for minutes: Int) -> String {
        let normalized = clamp(minutes: minutes)
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }
}

struct WidgetAutoRefreshSchedule: Equatable {
    let interval: WidgetRefreshInterval
    let window: WidgetAutoRefreshWindow
    let calendar: Calendar

    init?(
        interval: WidgetRefreshInterval,
        startMinutes: Int,
        endMinutes: Int,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        guard interval.isEnabled else {
            return nil
        }

        var normalizedCalendar = calendar
        normalizedCalendar.timeZone = timeZone

        self.interval = interval
        self.window = WidgetAutoRefreshWindow(startMinutes: startMinutes, endMinutes: endMinutes)
        self.calendar = normalizedCalendar
    }

    var signature: String {
        "\(interval.rawValue)|\(window.startMinutes)|\(window.endMinutes)"
    }

    func refreshDates(forDayContaining date: Date) -> [Date] {
        let dayStart = calendar.startOfDay(for: date)
        let startDate = dayStart.addingTimeInterval(TimeInterval(window.startMinutes * 60))
        let endDate = dayStart.addingTimeInterval(TimeInterval(window.endMinutes * 60))
        var dates: [Date] = []
        var candidate = startDate

        while candidate <= endDate {
            dates.append(candidate)
            candidate = candidate.addingTimeInterval(interval.timeInterval)
        }

        return dates
    }

    func nextRefreshDate(after referenceDate: Date) -> Date? {
        if let nextToday = refreshDates(forDayContaining: referenceDate).first(where: { $0 > referenceDate }) {
            return nextToday
        }

        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate)) else {
            return nil
        }
        return refreshDates(forDayContaining: tomorrow).first
    }
}

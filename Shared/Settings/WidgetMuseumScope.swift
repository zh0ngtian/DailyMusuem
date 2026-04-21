import Foundation
import WidgetKit

enum WidgetMuseumScope: Hashable, Codable {
    case all
    case single(MuseumID)
}

extension WidgetMuseumScope {
    var rawValue: String {
        switch self {
        case .all:
            return "all"
        case .single(let id):
            return "single:\(id.rawValue)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "all" { self = .all; return }
        if rawValue.hasPrefix("single:") {
            let value = String(rawValue.dropFirst("single:".count))
            if let id = MuseumID(rawValue: value) {
                self = .single(id)
                return
            }
        }
        return nil
    }
}

struct WidgetInstanceTokenResolver {
    static func makeDefaultToken() -> String {
        UUID().uuidString
    }

    static func resolve(
        from rawValue: String?,
        scope _: WidgetMuseumScope,
        family _: WidgetFamily?
    ) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }

        return makeDefaultToken()
    }
}

extension WidgetFamily {
    var debugToken: String {
        switch self {
        case .systemSmall:
            return "small"
        case .systemMedium:
            return "medium"
        case .systemLarge:
            return "large"
        default:
            return "other"
        }
    }
}

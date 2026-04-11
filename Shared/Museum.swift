import Foundation

struct Museum: Identifiable, Hashable, Codable {
    let id: MuseumID
    let displayName: String
    let subtitle: String
}

enum MuseumID: String, Codable, CaseIterable, Identifiable {
    case met
    case tnm
    case nmc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .met:
            return "大都会艺术博物馆"
        case .tnm:
            return "东京国立博物馆"
        case .nmc:
            return "中国国家博物馆"
        }
    }

    var subtitle: String {
        switch self {
        case .met:
            return "美国 纽约"
        case .tnm:
            return "日本 东京"
        case .nmc:
            return "中国 北京"
        }
    }

    var defaultTranslationSourceLanguage: String {
        switch self {
        case .met:
            return "en"
        case .tnm:
            return "ja"
        case .nmc:
            return "zh"
        }
    }

    var supportsTranslation: Bool {
        switch self {
        case .met, .tnm:
            return true
        case .nmc:
            return false
        }
    }
}

enum MuseumRepository {
    static let supportedMuseums: [Museum] = MuseumID.allCases.map {
        Museum(id: $0, displayName: $0.displayName, subtitle: $0.subtitle)
    }

    static func museum(for id: MuseumID) -> Museum {
        supportedMuseums.first(where: { $0.id == id }) ?? Museum(id: id, displayName: id.displayName, subtitle: id.subtitle)
    }

    static func museums(inPreferredOrder ids: [MuseumID]) -> [Museum] {
        var seen: Set<MuseumID> = []
        var ordered: [Museum] = []

        for id in ids where seen.insert(id).inserted {
            ordered.append(museum(for: id))
        }

        for museum in supportedMuseums where seen.insert(museum.id).inserted {
            ordered.append(museum)
        }

        return ordered
    }
}

import Foundation

struct Museum: Identifiable, Hashable, Codable {
    let id: MuseumID
    let displayName: String
    let subtitle: String
}

enum MuseumID: String, Codable, CaseIterable, Identifiable {
    case met
    case tnm

    var id: String { rawValue }

    var defaultTranslationSourceLanguage: String {
        switch self {
        case .met:
            return "en"
        case .tnm:
            return "ja"
        }
    }
}

enum MuseumRepository {
    static let supportedMuseums: [Museum] = [
        Museum(id: .met, displayName: "大都会艺术博物馆", subtitle: "美国 纽约"),
        Museum(id: .tnm, displayName: "东京国立博物馆", subtitle: "日本 东京")
    ]
}

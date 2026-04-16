import Foundation
import WidgetKit

struct WidgetArtworkEntry: TimelineEntry {
    let date: Date
    let renderID: String
    let familyKey: String
    let deliveryID: String
    let museumName: String
    let title: String
    let subtitle: String?
    let imageFileName: String?
    let appURL: URL?
    let isRefreshing: Bool

    init(
        date: Date,
        renderID: String,
        familyKey: String = "",
        deliveryID: String = "",
        museumName: String,
        title: String,
        subtitle: String?,
        imageFileName: String?,
        appURL: URL?,
        isRefreshing: Bool
    ) {
        self.date = date
        self.renderID = renderID
        self.familyKey = familyKey
        self.deliveryID = deliveryID
        self.museumName = museumName
        self.title = title
        self.subtitle = subtitle
        self.imageFileName = imageFileName
        self.appURL = appURL
        self.isRefreshing = isRefreshing
    }

    func scoped(to family: WidgetFamily, deliveryID: String = "") -> WidgetArtworkEntry {
        WidgetArtworkEntry(
            date: date,
            renderID: renderID,
            familyKey: family.logKey,
            deliveryID: deliveryID,
            museumName: museumName,
            title: title,
            subtitle: subtitle,
            imageFileName: imageFileName,
            appURL: appURL,
            isRefreshing: isRefreshing
        )
    }
}

extension WidgetFamily {
    var logKey: String {
        switch self {
        case .systemSmall:
            return "systemSmall"
        case .systemMedium:
            return "systemMedium"
        case .systemLarge:
            return "systemLarge"
        default:
            return String(describing: self)
        }
    }
}

actor WidgetDisplayedArtworkRegistry {
    static let shared = WidgetDisplayedArtworkRegistry()

    func displayedArtworkSummary(forFamilyKey familyKey: String) async -> String {
        "未知"
    }
}

import SwiftUI
import WidgetKit

struct DailyMuseumWidgetView: View {
    let entry: WidgetArtworkEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let _ = WidgetRenderProbe.markRenderStarted(entry, family: family)
        GeometryReader { proxy in
            ZStack {
                if let uiImage = WidgetImageLoader.image(fileName: entry.imageFileName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    Rectangle().fill(.quaternary)
                }

                VStack {
                    HStack {
                        Spacer()
                        Group {
                            if entry.isRefreshing {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            } else {
                                Button(intent: RefreshWidgetIntent()) {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                        .font(refreshIconFont)
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: refreshControlSize, height: refreshControlSize)
                    }

                    Spacer(minLength: 0)

                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(titleFont)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .lineLimit(maxTitleLines)
                                .multilineTextAlignment(.leading)

                            if let subtitle = entry.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(subtitleFont)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(textCardPadding)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: textCardCornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: textCardCornerRadius, style: .continuous)
                                .stroke(.white.opacity(0.18), lineWidth: 0.75)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(contentPadding)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .containerBackground(for: .widget) {
            Color.black
        }
        .id(entry.familyScopedRenderID)
        .widgetURL(entry.appURL)
        .task(id: entry.familyScopedRenderID) {
            await WidgetRenderProbe.markRenderCompleted(entry, family: family)
        }
    }

    private var titleFont: Font {
        switch family {
        case .systemSmall:
            return .footnote
        case .systemMedium:
            return .subheadline
        case .systemLarge:
            return .headline
        default:
            return .subheadline
        }
    }

    private var maxTitleLines: Int {
        switch family {
        case .systemSmall:
            return 3
        case .systemMedium:
            return 2
        case .systemLarge:
            return 3
        default:
            return 2
        }
    }

    private var subtitleFont: Font {
        switch family {
        case .systemSmall:
            return .caption2
        case .systemMedium:
            return .caption
        case .systemLarge:
            return .caption
        default:
            return .caption
        }
    }

    private var refreshIconFont: Font {
        switch family {
        case .systemSmall:
            return .title3
        case .systemMedium:
            return .title2
        case .systemLarge:
            return .largeTitle
        default:
            return .title3
        }
    }

    private var textCardPadding: CGFloat {
        switch family {
        case .systemSmall:
            return 8
        case .systemMedium:
            return 10
        case .systemLarge:
            return 12
        default:
            return 10
        }
    }

    private var textCardCornerRadius: CGFloat {
        switch family {
        case .systemSmall:
            return 12
        case .systemMedium:
            return 14
        case .systemLarge:
            return 16
        default:
            return 14
        }
    }

    private var contentPadding: CGFloat {
        switch family {
        case .systemSmall:
            return 10
        case .systemMedium:
            return 12
        case .systemLarge:
            return 14
        default:
            return 12
        }
    }

    private var refreshControlSize: CGFloat {
        switch family {
        case .systemSmall:
            return 24
        case .systemMedium:
            return 28
        case .systemLarge:
            return 34
        default:
            return 24
        }
    }
}

private enum WidgetImageLoader {
    static func image(fileName: String?) -> UIImage? {
        guard let fileName,
              let imageURL = WidgetArtworkSnapshotStore.imageURL(for: fileName) else {
            return nil
        }
        return UIImage(contentsOfFile: imageURL.path)
    }
}

private enum WidgetRenderProbe {
    static func markRenderStarted(_ entry: WidgetArtworkEntry, family: WidgetFamily) {
        Task {
            await WidgetRenderState.shared.logRenderStartedIfNeeded(entry: entry, family: family)
        }
    }

    static func markRenderCompleted(_ entry: WidgetArtworkEntry, family: WidgetFamily) async {
        await WidgetRenderState.shared.logRenderCompletedIfNeeded(entry: entry, family: family)
    }
}

private actor WidgetRenderState {
    static let shared = WidgetRenderState()

    private var startedRenderIDs: Set<String> = []
    private var completedRenderIDs: Set<String> = []

    func logRenderStartedIfNeeded(entry: WidgetArtworkEntry, family: WidgetFamily) async {
        let renderLogKey = entry.familyScopedRenderID
        guard startedRenderIDs.insert(renderLogKey).inserted else {
            return
        }
        await RequestLogger.shared.logEvent(
            source: "Widget 渲染",
            summary: "开始渲染 \(entry.museumName) / \(entry.title)，family=\(family.logLabel)，deliveryID=\(entry.deliveryID.isEmpty ? "-" : entry.deliveryID)，renderID=\(entry.familyScopedRenderID)，图片文件=\(imageState(for: entry))"
        )
    }

    func logRenderCompletedIfNeeded(entry: WidgetArtworkEntry, family: WidgetFamily) async {
        let renderLogKey = entry.familyScopedRenderID
        guard completedRenderIDs.insert(renderLogKey).inserted else {
            return
        }

        let displayState = await WidgetDisplayedArtworkRegistry.shared.recordDisplayedEntry(entry, family: family)
        let installedFamilyCounts = await WidgetConfigurationInspector.currentInstalledFamilyCounts()
        await RequestLogger.shared.logEvent(
            source: "Widget 渲染",
            summary: "渲染完成 \(entry.museumName) / \(entry.title)，family=\(family.logLabel)，deliveryID=\(entry.deliveryID.isEmpty ? "-" : entry.deliveryID)，renderID=\(entry.familyScopedRenderID)，图片文件=\(imageState(for: entry))，当前各小组件显示：\(displayState.summary(installedFamilyCounts: installedFamilyCounts))"
        )
    }

    private func imageState(for entry: WidgetArtworkEntry) -> String {
        entry.imageFileName.flatMap { WidgetArtworkSnapshotStore.imageURL(for: $0) }
            .map { FileManager.default.fileExists(atPath: $0.path) ? "存在" : "缺失" }
            ?? "无图"
    }
}

private enum WidgetConfigurationInspector {
    static func currentInstalledFamilyCounts() async -> [String: Int] {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let familyCounts: [String: Int]
                switch result {
                case .success(let widgetInfos):
                    var counts: [String: Int] = [
                        "systemLarge": 0,
                        "systemMedium": 0,
                        "systemSmall": 0,
                    ]
                    for widgetInfo in widgetInfos where widgetInfo.kind == SettingsKeys.widgetKind {
                        counts[widgetInfo.family.logKey, default: 0] += 1
                    }
                    familyCounts = counts
                case .failure:
                    familyCounts = [:]
                }
                continuation.resume(returning: familyCounts)
            }
        }
    }
}

private actor WidgetDisplayedArtworkRegistry {
    static let shared = WidgetDisplayedArtworkRegistry()

    private enum Constants {
        static let directoryName = "WidgetRender"
        static let fileName = "displayed-artworks.json"
    }

    struct State: Codable {
        var displayedByFamily: [String: DisplayedArtwork]

        func summary(installedFamilyCounts: [String: Int]) -> String {
            let familyOrder = ["systemLarge", "systemMedium", "systemSmall"]
            let hasInstalledFamilyCounts = installedFamilyCounts.values.contains { $0 > 0 }
            let familyKeys: [String]

            if hasInstalledFamilyCounts {
                familyKeys = familyOrder.filter { installedFamilyCounts[$0, default: 0] > 0 }
            } else {
                familyKeys = familyOrder.filter { displayedByFamily[$0] != nil }
            }

            guard !familyKeys.isEmpty else {
                return "暂无已记录的小组件显示信息"
            }

            return familyKeys.map { familyKey in
                let count = installedFamilyCounts[familyKey, default: 0]
                let countSuffix = count > 0 ? "x\(count)" : ""
                guard let displayedArtwork = displayedByFamily[familyKey] else {
                    return "\(familyKey)\(countSuffix)=未记录"
                }
                return "\(familyKey)\(countSuffix)=\(displayedArtwork.summary)"
            }
            .joined(separator: "；")
        }
    }

    struct DisplayedArtwork: Codable {
        let familyKey: String
        let museumName: String
        let title: String
        let subtitle: String?
        let renderID: String
        let deliveryID: String
        let imageFileName: String?
        let isRefreshing: Bool
        let updatedAt: TimeInterval

        var summary: String {
            let titleSummary = "\(museumName) / \(title)"
            let subtitleSummary = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = subtitleSummary.flatMap { $0.isEmpty ? nil : $0 }

            if isRefreshing {
                if let details {
                    return "加载态（\(titleSummary) / \(details)）"
                }
                return "加载态（\(titleSummary)）"
            }

            if let details {
                return "\(titleSummary) / \(details)"
            }
            return titleSummary
        }
    }

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: SettingsKeys.appGroupID)
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        fileURL = baseURL
            .appendingPathComponent(Constants.directoryName, isDirectory: true)
            .appendingPathComponent(Constants.fileName)
    }

    func recordDisplayedEntry(_ entry: WidgetArtworkEntry, family: WidgetFamily, now: Date = .now) -> State {
        var state = loadState() ?? State(displayedByFamily: [:])
        state.displayedByFamily[family.logKey] = DisplayedArtwork(
            familyKey: family.logKey,
            museumName: entry.museumName,
            title: entry.title,
            subtitle: entry.subtitle,
            renderID: entry.familyScopedRenderID,
            deliveryID: entry.deliveryID,
            imageFileName: entry.imageFileName,
            isRefreshing: entry.isRefreshing,
            updatedAt: now.timeIntervalSince1970
        )
        persist(state)
        return state
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? decoder.decode(State.self, from: data) else {
            return nil
        }
        return state
    }

    private func persist(_ state: State) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Ignore display-state persistence failures to avoid affecting widget rendering.
        }
    }
}

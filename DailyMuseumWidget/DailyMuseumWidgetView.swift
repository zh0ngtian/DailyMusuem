import SwiftUI
import WidgetKit

struct DailyMuseumWidgetView: View {
    let entry: WidgetArtworkEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let _ = WidgetRenderProbe.markRendered(entry, family: family)
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
    static func markRendered(_ entry: WidgetArtworkEntry, family: WidgetFamily) {
        Task {
            await WidgetRenderState.shared.logIfNeeded(entry: entry, family: family)
        }
    }
}

private actor WidgetRenderState {
    static let shared = WidgetRenderState()

    private var loggedRenderIDs: Set<String> = []

    func logIfNeeded(entry: WidgetArtworkEntry, family: WidgetFamily) async {
        let renderLogKey = entry.familyScopedRenderID
        guard loggedRenderIDs.insert(renderLogKey).inserted else {
            return
        }
        let imageState = entry.imageFileName.flatMap { WidgetArtworkSnapshotStore.imageURL(for: $0) }
            .map { FileManager.default.fileExists(atPath: $0.path) ? "存在" : "缺失" }
            ?? "无图"
        await RequestLogger.shared.logEvent(
            source: "Widget 渲染",
            summary: "开始渲染 \(entry.museumName) / \(entry.title)，family=\(family.logLabel)，deliveryID=\(entry.deliveryID.isEmpty ? "-" : entry.deliveryID)，renderID=\(entry.familyScopedRenderID)，图片文件=\(imageState)"
        )
    }
}

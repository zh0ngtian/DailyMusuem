import SwiftUI
import WidgetKit

struct DailyMuseumWidgetView: View {
    let entry: WidgetArtworkEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let backgroundImage = widgetImage(for: proxy.size)

            ZStack {
                backgroundView(size: proxy.size, image: backgroundImage)

                VStack {
                    HStack {
                        Spacer()
                        refreshControl
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

                            if let subtitle = displaySubtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(subtitleFont)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(maxSubtitleLines)
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
        .id(entry.renderID)
        .widgetURL(entry.appURL)
    }

    private var refreshControl: some View {
        Button(
            intent: RefreshWidgetIntent(
                refreshKey: entry.refreshKey,
                museumScope: configuredScope,
                widgetFamilyToken: family.debugToken
            )
        ) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(refreshIconFont)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .frame(width: refreshControlSize, height: refreshControlSize)
    }

    private func backgroundView(size: CGSize, image: UIImage?) -> some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                LinearGradient(
                    colors: backgroundGradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            Rectangle()
                .fill(.black.opacity(backgroundOverlayOpacity(hasImage: image != nil)))
        }
    }

    private func widgetImage(for size: CGSize) -> UIImage? {
        guard let fileName = entry.imageFileName else {
            return nil
        }
        return WidgetArtworkSnapshotStore.widgetImage(
            for: fileName,
            targetPointSize: size,
            scale: displayScale
        )
    }

    private var configuredScope: WidgetConfiguredMuseumScope {
        guard let scope = WidgetMuseumScope(rawValue: entry.scopeRawValue) else {
            return .all
        }
        switch scope {
        case .all:
            return .all
        case .single(.met):
            return .met
        case .single(.tnm):
            return .tnm
        case .single(.nmc):
            return .nmc
        case .single(.shm):
            return .shm
        }
    }

    private var displaySubtitle: String? {
        switch entry.phase {
        case .idle, .refreshing:
            return "长按小组件，选择「编辑小组件」以改变展品展示范围"
        case .success:
            return entry.subtitle
        case .failure:
            return entry.failureMessage?.removingTrailingSentencePeriods ?? "请重试"
        }
    }

    private var backgroundGradientColors: [Color] {
        switch entry.phase {
        case .idle, .refreshing:
            return [Color(red: 0.15, green: 0.22, blue: 0.34), Color(red: 0.07, green: 0.09, blue: 0.12)]
        case .success:
            return [Color(red: 0.20, green: 0.20, blue: 0.20), Color.black]
        case .failure:
            return [Color(red: 0.15, green: 0.22, blue: 0.34), Color(red: 0.07, green: 0.09, blue: 0.12)]
        }
    }

    private func backgroundOverlayOpacity(hasImage: Bool) -> Double {
        switch entry.phase {
        case .success:
            return hasImage ? 0.30 : 0.18
        case .idle, .refreshing, .failure:
            return 0.18
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

    private var maxSubtitleLines: Int {
        switch entry.phase {
        case .idle, .refreshing:
            return family == .systemSmall ? 3 : 2
        case .success, .failure:
            break
        }

        switch family {
        case .systemLarge:
            return 2
        default:
            return 1
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

private extension String {
    var removingTrailingSentencePeriods: String {
        var result = self
        while result.last == "." || result.last == "。" {
            result.removeLast()
        }
        return result
    }
}

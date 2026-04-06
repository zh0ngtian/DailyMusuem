import SwiftUI
import WidgetKit

struct DailyMuseumWidgetView: View {
    let entry: WidgetArtworkEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let data = entry.imageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay {
                            LinearGradient(
                                colors: [.black.opacity(0.08), .black.opacity(0.82)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                } else {
                    Rectangle().fill(.quaternary)
                }

                VStack {
                    HStack {
                        Spacer()
                        Button(intent: RefreshWidgetIntent()) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(refreshIconFont)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
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
}

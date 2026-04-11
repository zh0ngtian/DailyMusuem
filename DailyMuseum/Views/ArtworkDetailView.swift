import SwiftUI

struct ArtworkDetailView: View {
    private enum Constants {
        static let placeholderAspectRatio: CGFloat = 0.8
    }

    let artwork: Artwork
    let placeholderAspectRatio: CGFloat
    let imageReloadToken: Int
    let showsTranslationButton: Bool
    let translationButtonTitle: String
    let translationButtonDisabled: Bool
    let onTranslationButtonTap: () async -> Void
    let onRefresh: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CachedAsyncImage(url: artwork.primaryImageURL ?? artwork.primaryImageSmallURL) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    detailPlaceholderImage
                }
                .id(imageReloadToken)
                .frame(maxWidth: .infinity)
                .aspectRatio(effectivePlaceholderAspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text(artwork.title)
                        .font(.title2.weight(.semibold))

                    if let subtitle = artwork.subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    if let description = artwork.normalizedDescriptionText {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("展品介绍")
                                .font(.headline)
                            Text(description)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 4)
                    }

                    InfoRow(label: "年代", value: artwork.objectDate)
                    InfoRow(label: "材质", value: artwork.medium)
                    InfoRow(label: "尺寸", value: artwork.dimensions)
                    InfoRow(label: "部门", value: artwork.department)
                    InfoRow(label: "文化", value: artwork.culture)
                    InfoRow(label: "国家", value: artwork.country)
                    InfoRow(label: "馆藏", value: artwork.repository)

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = artwork.objectURL {
                ToolbarItem(placement: .topBarTrailing) {
                    Link("官网", destination: url)
                }
            }
            if showsTranslationButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(translationButtonTitle) {
                        Task {
                            await onTranslationButtonTap()
                        }
                    }
                    .disabled(translationButtonDisabled)
                }
            }
        }
        .refreshable {
            await onRefresh()
        }
    }

    private var detailPlaceholderImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemGray5))

            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 30, weight: .medium))
                Text("加载图片中")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var effectivePlaceholderAspectRatio: CGFloat {
        guard placeholderAspectRatio.isFinite, placeholderAspectRatio > 0 else {
            return Constants.placeholderAspectRatio
        }
        return placeholderAspectRatio
    }
}

private struct InfoRow: View {
    let label: String
    let value: String?

    var body: some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        }
    }
}

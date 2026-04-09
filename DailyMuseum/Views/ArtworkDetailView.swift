import SwiftUI

struct ArtworkDetailView: View {
    let artwork: Artwork
    let imageReloadToken: Int
    let onRefresh: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CachedAsyncImage(url: artwork.primaryImageURL ?? artwork.primaryImageSmallURL) { image in
                    image
                        .resizable()
                        .scaledToFit()
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .id(imageReloadToken)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text(artwork.title)
                        .font(.title2.weight(.semibold))

                    if let subtitle = artwork.subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    InfoRow(label: "年代", value: artwork.objectDate)
                    InfoRow(label: "材质", value: artwork.medium)
                    InfoRow(label: "尺寸", value: artwork.dimensions)
                    InfoRow(label: "部门", value: artwork.department)
                    InfoRow(label: "文化", value: artwork.culture)
                    InfoRow(label: "国家", value: artwork.country)
                    InfoRow(label: "馆藏", value: artwork.repository)

                    if let url = artwork.objectURL {
                        Link("在官网查看", destination: url)
                            .font(.headline)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .navigationTitle("展品")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await onRefresh()
        }
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

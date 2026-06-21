import SwiftUI

struct MuseumListView: View {
    @State private var selectedMuseum: Museum?
    @State private var countrySections: [MuseumCountrySection] = []
    @State private var isLoadingMetadata = true
    @State private var metadataErrorMessage: String?

    var body: some View {
        museumList
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedMuseum) { museum in
            ArtworkFeedView(museum: museum)
        }
        .task {
            await loadMuseumMetadata(cachePolicy: .useCaches, useCachedSnapshot: true)
        }
        .refreshable {
            await loadMuseumMetadata(cachePolicy: .networkOnly, useCachedSnapshot: false)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink(value: Route.favorites) {
                    Image(systemName: "star")
                }
                .accessibilityLabel("收藏夹")

                NavigationLink(value: Route.settings) {
                    Image(systemName: "gear")
                }
                .accessibilityLabel("设置")
            }
        }
    }

    private var museumList: some View {
        Group {
            if countrySections.isEmpty {
                ContentUnavailableView(
                    isLoadingMetadata ? "正在加载博物馆" : "暂无可展示博物馆",
                    systemImage: isLoadingMetadata ? "hourglass" : "building.columns",
                    description: Text(metadataErrorMessage ?? "请稍后重试")
                )
            } else {
                List {
                    ForEach(countrySections) { section in
                        Section {
                            ForEach(section.museums) { museum in
                                Button {
                                    selectedMuseum = museum
                                } label: {
                                    museumCard(museum, showsChevron: true)
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        } header: {
                            Text(section.country)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                                .padding(.leading, 4)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func museumCard(_ museum: Museum, showsChevron: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            museumLogoBadge(for: museum)

            VStack(alignment: .leading, spacing: 6) {
                Text(museum.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(museum.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.background)
                .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 6)
        )
    }

    private func museumLogoBadge(for museum: Museum) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(logoBackgroundColor(for: museum))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            }
            .overlay {
                if let iconURL = museum.iconURL {
                    CachedAsyncImage(url: iconURL) { image in
                        logoImage(image)
                    } placeholder: {
                        fallbackLogoImage(for: museum)
                    }
                } else if let iconAssetName = museum.iconAssetName, !iconAssetName.isEmpty {
                    logoImage(Image(iconAssetName))
                } else {
                    fallbackLogoImage(for: museum)
                }
            }
            .frame(width: 112, height: 68)
    }

    private func loadMuseumMetadata(
        cachePolicy: MuseumRequestCachePolicy,
        useCachedSnapshot: Bool
    ) async {
        if useCachedSnapshot,
           let cachedSections = Self.countrySections(from: MuseumMetadataStore.cachedSnapshot()?.museums),
           !cachedSections.isEmpty {
            countrySections = cachedSections
            metadataErrorMessage = nil
        }

        if countrySections.isEmpty {
            isLoadingMetadata = true
        }

        do {
            let metadata = try await MuseumMetadataStore.shared.refresh(cachePolicy: cachePolicy)
            if let refreshedSections = Self.countrySections(from: metadata), !refreshedSections.isEmpty {
                countrySections = refreshedSections
                metadataErrorMessage = nil
            } else {
                metadataErrorMessage = "服务端未返回可展示博物馆。"
            }
        } catch {
            metadataErrorMessage = error.localizedDescription
        }
        isLoadingMetadata = false
    }

    private static func countrySections(from metadata: [MuseumMetadata]?) -> [MuseumCountrySection]? {
        guard let metadata, !metadata.isEmpty else {
            return nil
        }

        let museums = metadata
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .map { $0.toMuseum() }

        var countries: [String] = []
        var museumsByCountry: [String: [Museum]] = [:]
        for museum in museums {
            let country = museum.country.isEmpty ? "其他" : museum.country
            if museumsByCountry[country] == nil {
                countries.append(country)
            }
            museumsByCountry[country, default: []].append(museum)
        }

        return countries.compactMap { country in
            guard let museums = museumsByCountry[country], !museums.isEmpty else {
                return nil
            }
            return MuseumCountrySection(country: country, museums: museums)
        }
    }

    private func logoBackgroundColor(for museum: Museum) -> Color {
        Color(museumHex: museum.iconBackgroundColor) ?? Color(.secondarySystemBackground)
    }

    private func fallbackLogoImage(for museum: Museum) -> some View {
        logoImage(Image(museum.id.homepageLogoAssetName))
    }

    private func logoImage(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 90, maxHeight: 46)
            .accessibilityHidden(true)
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
    }
}

private extension Color {
    init?(museumHex rawValue: String?) {
        guard var hex = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6, let value = Int(hex, radix: 16) else {
            return nil
        }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

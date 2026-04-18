import SwiftUI

struct FavoritesView: View {
    @StateObject private var favorites = FavoritesStore.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var selectedArtworkReference: ArtworkReference?

    private var sections: [FavoriteSection] {
        favorites.groupedFavorites(orderedMuseumIDs: settings.orderedMuseums().map(\.id))
    }

    var body: some View {
        Group {
            if sections.isEmpty {
                ContentUnavailableView(
                    "暂无收藏",
                    systemImage: "star",
                    description: Text("在展品详情页点右上角星标后，这里会显示你收藏的展品。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .background(Color(.systemGroupedBackground))
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { snapshot in
                                Button {
                                    selectedArtworkReference = snapshot.reference
                                } label: {
                                    ArtworkListRowCardView(artwork: snapshot.artwork)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        removeFavorite(snapshot)
                                    } label: {
                                        Label("取消收藏", systemImage: "trash")
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("收藏夹")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedArtworkReference) { reference in
            ArtworkDetailLoaderView(reference: reference)
        }
    }

    private func removeFavorite(_ snapshot: FavoriteArtworkSnapshot) {
        if selectedArtworkReference?.museumID == snapshot.museumID &&
            selectedArtworkReference?.objectID == snapshot.objectID {
            selectedArtworkReference = nil
        }

        favorites.removeFavorite(museumID: snapshot.museumID, objectID: snapshot.objectID)
    }
}

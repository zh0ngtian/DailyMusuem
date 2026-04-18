import SwiftUI

struct MuseumListView: View {
    @StateObject private var settings = SettingsStore.shared
    @State private var museums: [Museum] = []
    @State private var isSorting = false
    @State private var selectedMuseum: Museum?

    var body: some View {
        List {
            if isSorting {
                Section {
                    Text("长按后拖动右侧手柄调整顺序，完成后点右上角“完成”。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                ForEach(museums) { museum in
                    Group {
                        if isSorting {
                            museumCard(museum, showsChevron: false)
                        } else {
                            Button {
                                selectedMuseum = museum
                            } label: {
                                museumCard(museum, showsChevron: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .moveDisabled(!isSorting)
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in
                                guard !isSorting else { return }
                                museums = settings.orderedMuseums()
                                withAnimation(.spring(duration: 0.25, bounce: 0.12)) {
                                    isSorting = true
                                }
                            }
                    )
                }
                .onMove(perform: moveMuseums)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedMuseum) { museum in
            ArtworkFeedView(museum: museum)
        }
        .environment(\.editMode, .constant(isSorting ? .active : .inactive))
        .task {
            if museums.isEmpty {
                museums = settings.orderedMuseums()
            }
        }
        .onChange(of: settings.museumDisplayOrderRawValue) { _, _ in
            guard !isSorting else { return }
            museums = settings.orderedMuseums()
        }
        .toolbar {
            if isSorting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSorting = false
                        }
                    }
                }
            } else {
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
    }

    @ViewBuilder
    private func museumCard(_ museum: Museum, showsChevron: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(museum.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(museum.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

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

    private func moveMuseums(from source: IndexSet, to destination: Int) {
        museums.move(fromOffsets: source, toOffset: destination)
        settings.saveMuseumOrder(museums)
    }
}

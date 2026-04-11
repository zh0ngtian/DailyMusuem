import SwiftUI

struct RootView: View {
    private enum LogPanelSnapPoint: CaseIterable {
        case oneThird
        case half
        case full

        var ratio: CGFloat {
            switch self {
            case .oneThird:
                return 1.0 / 3.0
            case .half:
                return 0.5
            case .full:
                return 0.94
            }
        }
    }

    private enum Constants {
        static let defaultLogPanelSnapPoint: LogPanelSnapPoint = .half
    }

    @ObservedObject var router: AppRouter
    @State private var isLogPanelPresented = false
    @State private var logPanelSnapPoint: LogPanelSnapPoint = Constants.defaultLogPanelSnapPoint

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                NavigationStack(path: $router.path) {
                    MuseumListView()
                        .navigationDestination(for: Route.self) { route in
                            destinationView(for: route)
                        }
                }

                if isLogPanelPresented {
                    logPanel(
                        containerHeight: proxy.size.height,
                        bottomSafeAreaInset: proxy.safeAreaInsets.bottom
                    )
                }

                if !isLogPanelPresented {
                    logButton
                }
            }
        }
    }

    @ViewBuilder
    private func destinationView(for route: Route) -> some View {
        switch route {
        case .museum(let museum):
            ArtworkFeedView(museum: museum)
        case .artwork(let reference):
            ArtworkDetailLoaderView(reference: reference)
        case .settings:
            SettingsView()
        }
    }

    private func logPanel(containerHeight: CGFloat, bottomSafeAreaInset: CGFloat) -> some View {
        let contentHeight = resolvedLogPanelHeight(containerHeight: containerHeight)

        return VStack(spacing: 0) {
            RequestLogsView(
                style: .panel,
                onClose: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isLogPanelPresented = false
                    }
                },
                selectedPanelSizeOption: panelSizeOption(for: logPanelSnapPoint),
                onSelectPanelSizeOption: { option in
                    withAnimation(.spring(duration: 0.28, bounce: 0.18)) {
                        logPanelSnapPoint = snapPoint(for: option)
                    }
                }
            )
            .frame(maxHeight: .infinity, alignment: .top)

            Color(.systemBackground)
                .frame(height: bottomSafeAreaInset)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .frame(height: contentHeight + bottomSafeAreaInset, alignment: .bottom)
        .background(Color(.systemBackground))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 24,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: -2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .ignoresSafeArea(edges: .bottom)
    }

    private var logButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if !isLogPanelPresented {
                    logPanelSnapPoint = Constants.defaultLogPanelSnapPoint
                }
                isLogPanelPresented.toggle()
            }
        } label: {
            Image(systemName: isLogPanelPresented ? "xmark.bubble.fill" : "doc.text.magnifyingglass")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.black, in: Circle())
        }
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
        .padding(.leading, 16)
        .padding(.bottom, 16)
    }

    private func resolvedLogPanelHeight(containerHeight: CGFloat) -> CGFloat {
        containerHeight * logPanelSnapPoint.ratio
    }

    private func panelSizeOption(for snapPoint: LogPanelSnapPoint) -> RequestLogsView.PanelSizeOption {
        switch snapPoint {
        case .oneThird:
            return .oneThird
        case .half:
            return .half
        case .full:
            return .full
        }
    }

    private func snapPoint(for option: RequestLogsView.PanelSizeOption) -> LogPanelSnapPoint {
        switch option {
        case .oneThird:
            return .oneThird
        case .half:
            return .half
        case .full:
            return .full
        }
    }
}

enum Route: Hashable {
    case museum(Museum)
    case artwork(ArtworkReference)
    case settings
}

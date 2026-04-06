import SwiftUI

struct WaterfallGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let columnCount: Int
    let availableWidth: CGFloat
    let cell: (Item) -> Cell
    var spacing: CGFloat = 12

    init(items: [Item], columnCount: Int, availableWidth: CGFloat, spacing: CGFloat = 12, @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.items = items
        self.columnCount = max(1, columnCount)
        self.availableWidth = availableWidth
        self.spacing = spacing
        self.cell = cell
    }

    var body: some View {
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let columnWidth = max(0, (availableWidth - totalSpacing) / CGFloat(columnCount))
        let columns = makeColumns(columnWidth: columnWidth)

        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columnCount, id: \.self) { index in
                LazyVStack(spacing: spacing) {
                    ForEach(columns[index]) { item in
                        cell(item)
                            .frame(width: columnWidth)
                    }
                }
                .frame(width: columnWidth, alignment: .top)
            }
        }
        .frame(width: availableWidth, alignment: .top)
    }

    private func makeColumns(columnWidth: CGFloat) -> [[Item]] {
        var columns: [[Item]] = Array(repeating: [], count: columnCount)
        var heights: [CGFloat] = Array(repeating: 0, count: columnCount)

        for item in items {
            let index = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            columns[index].append(item)

            let estimatedHeight = estimateHeight(for: item, columnWidth: columnWidth)
            heights[index] += estimatedHeight + spacing
        }

        return columns
    }

    private func estimateHeight(for item: Item, columnWidth: CGFloat) -> CGFloat {
        if let feedItem = item as? ArtworkFeedItem {
            let ratio = feedItem.imageAspectRatio ?? 0.78
            let imageHeight = columnWidth / max(0.2, ratio)
            let textHeight: CGFloat = 64
            return imageHeight + textHeight
        }

        return columnWidth
    }
}

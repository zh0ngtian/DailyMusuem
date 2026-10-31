import SwiftUI

struct WidgetRefreshToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        // WidgetKit applies this optimistic toggle state before the intent finishes.
        // A new timeline resets it; never spin indefinitely while awaiting the network.
        configuration.label
            .rotationEffect(.degrees(configuration.isOn && !reduceMotion ? 359 : 0))
            .animation(configuration.isOn && !reduceMotion ? .linear(duration: 2) : nil,
                       value: configuration.isOn)
    }
}

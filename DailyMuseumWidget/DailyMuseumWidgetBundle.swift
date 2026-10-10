import WidgetKit
import SwiftUI

@main
struct DailyMuseumWidgetBundle: WidgetBundle {
    var body: some Widget {
        #if WIDGET_COMPATIBILITY
            CompatibleMuseumWidget<CompatibleWidgetSlot1>()
            CompatibleMuseumWidget<CompatibleWidgetSlot2>()
            CompatibleMuseumWidget<CompatibleWidgetSlot3>()
            CompatibleMuseumWidget<CompatibleWidgetSlot4>()
            CompatibleMuseumWidget<CompatibleWidgetSlot5>()
            CompatibleMuseumWidget<CompatibleWidgetSlot6>()
            CompatibleMuseumWidget<CompatibleWidgetSlot7>()
            CompatibleMuseumWidget<CompatibleWidgetSlot8>()
            CompatibleMuseumWidget<CompatibleWidgetSlot9>()
            CompatibleMuseumWidget<CompatibleWidgetSlot10>()
        #else
            DailyMuseumWidget()
        #endif
    }
}


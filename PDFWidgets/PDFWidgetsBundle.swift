import SwiftUI
import WidgetKit

@main
struct PDFWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuickActionsWidget()
        RecentDocumentsWidget()
        ScanLockScreenWidget()
    }
}

import SwiftUI

private struct ScreenTrackingModifier: ViewModifier {
    let screen: AnalyticsScreen
    @State private var appearedAt: Date?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { begin() }
            .onDisappear { end() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: if appearedAt == nil { begin() }
                case .background: end()
                default: break
                }
            }
    }

    private func begin() {
        guard appearedAt == nil else { return }
        appearedAt = Date()
        AppAnalytics.screen(screen)
    }

    private func end() {
        guard let start = appearedAt else { return }
        appearedAt = nil
        let seconds = AppAnalytics.seconds(since: start)
        guard seconds >= 1 else { return }
        AppAnalytics.log(.screenTime, [
            .screenName: screen.rawValue,
            .seconds: min(seconds, 4 * 3600),
        ])
    }
}

extension View {
    func trackScreen(_ screen: AnalyticsScreen) -> some View {
        modifier(ScreenTrackingModifier(screen: screen))
    }
}

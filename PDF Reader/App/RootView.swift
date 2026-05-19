import SwiftUI

/// Composition root for PDF AI.
///
/// Adaptive shell: tab bar on iPhone, sidebar on iPad/Mac via `sidebarAdaptable`.
/// Each tab is the entry point of a feature module.
struct RootView: View {
    @State private var selection: Destination = .library

    var body: some View {
        TabView(selection: $selection) {
            Tab("Library", systemImage: "books.vertical", value: Destination.library) {
                LibraryHomeView()
            }
            Tab("Read", systemImage: "doc.text", value: Destination.reader) {
                ReaderHomeView()
            }
            Tab("AI", systemImage: "sparkles", value: Destination.ai) {
                AIAssistantView()
            }
            Tab("Tools", systemImage: "wrench.and.screwdriver", value: Destination.tools) {
                ToolsHomeView()
            }
            Tab("Settings", systemImage: "gearshape", value: Destination.settings) {
                SettingsHomeView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

private enum Destination: Hashable {
    case library, reader, ai, tools, settings
}

#Preview {
    RootView()
}

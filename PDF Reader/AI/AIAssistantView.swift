import SwiftUI
import FoundationModels

/// AI — On-device Foundation Models integration: chat-with-PDF, summarize, translate,
/// extract data, form auto-fill. The product differentiator.
///
/// This top-level view shows availability state. The interactive surfaces
/// (Summarize, Chat) are launched from the Reader once a document is open.
struct AIAssistantView: View {
    private let model = SystemLanguageModel.default

    var body: some View {
        NavigationStack {
            Group {
                switch model.availability {
                case .available:
                    ready
                case .unavailable(.deviceNotEligible):
                    unavailable(
                        "Apple Intelligence isn't supported on this device.",
                        systemImage: "sparkles.slash"
                    )
                case .unavailable(.appleIntelligenceNotEnabled):
                    unavailable(
                        "Turn on Apple Intelligence in Settings to use AI features.",
                        systemImage: "sparkles.slash"
                    )
                case .unavailable(.modelNotReady):
                    unavailable(
                        "The on-device model is downloading. Try again in a few minutes.",
                        systemImage: "arrow.down.circle"
                    )
                case .unavailable:
                    unavailable(
                        "AI features are currently unavailable.",
                        systemImage: "sparkles.slash"
                    )
                }
            }
            .navigationTitle("AI")
        }
    }

    private var ready: some View {
        ContentUnavailableView {
            Label("AI Assistant", systemImage: "sparkles")
        } description: {
            Text("Open a PDF and tap **Summarize** to get a private, on-device summary. Chat, translate, and extract data are coming next.")
        }
    }

    private func unavailable(_ message: String, systemImage: String) -> some View {
        ContentUnavailableView(
            "AI Unavailable",
            systemImage: systemImage,
            description: Text(message)
        )
    }
}

#Preview {
    AIAssistantView()
}

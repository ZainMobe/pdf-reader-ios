import SwiftUI

/// Sheet that streams an AI-generated summary of a `Document`.
struct SummarySheet: View {
    let document: Document
    @State private var summarizer = DocumentSummarizer()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(DesignSystem.Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("AI Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "sparkles")
                        Text("On-device")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                summarizer.summarize(document)
            }
            .onDisappear {
                summarizer.cancel()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch summarizer.state {
        case .idle, .loading:
            ProgressView("Reading document…")
                .frame(maxWidth: .infinity)
                .padding(.top, DesignSystem.Spacing.xxl)
        case .streaming(let text), .done(let text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't summarize",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}

import SwiftUI

/// Sheet that renders structured data extracted from the document via
/// `DocumentExtractor`. Empty fields are hidden so the result reads cleanly.
struct ExtractSheet: View {
    let document: Document
    @State private var extractor = DocumentExtractor()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(DesignSystem.Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Extracted Data")
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
            .task { extractor.extract(document) }
            .onDisappear { extractor.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch extractor.state {
        case .idle, .loading:
            VStack(spacing: DesignSystem.Spacing.m) {
                ProgressView()
                Text("Analyzing document…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DesignSystem.Spacing.xxl)
        case .done(let data):
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.l) {
                Text(data.subject.isEmpty ? document.title : data.subject)
                    .font(.title2.weight(.semibold))

                if !data.dates.isEmpty {
                    section("Dates", systemImage: "calendar", items: data.dates)
                }
                if !data.entities.isEmpty {
                    section("People & Organizations", systemImage: "person.2", items: data.entities)
                }
                if !data.amounts.isEmpty {
                    section("Amounts", systemImage: "dollarsign.circle", items: data.amounts)
                }
                if !data.keyPoints.isEmpty {
                    section("Key Points", systemImage: "list.bullet", items: data.keyPoints)
                }
                if data.dates.isEmpty && data.entities.isEmpty && data.amounts.isEmpty && data.keyPoints.isEmpty {
                    Text("Nothing structured to extract.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            ContentUnavailableView(
                "Extraction failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private func section(_ title: String, systemImage: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: DesignSystem.Spacing.s) {
                        Text("•").foregroundStyle(.tint)
                        Text(item)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(DesignSystem.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
    }
}

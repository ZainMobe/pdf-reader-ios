import SwiftUI

/// Sheet that runs `FormAutoFiller` against a document and lets the user
/// review, edit, toggle, and apply AI-suggested field values.
struct FormFillSheet: View {
    let document: Document
    let onApplied: () -> Void

    @State private var filler = FormAutoFiller()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Auto-Fill Form")
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
                .task { filler.analyzeAndSuggest(document) }
                .onDisappear { filler.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch filler.state {
        case .idle, .detecting:
            progress("Detecting form fields…")
        case .suggesting:
            progress("Generating suggestions…")
        case .ready:
            reviewList
        case .noFields:
            ContentUnavailableView(
                "No Fillable Fields",
                systemImage: "doc.text",
                description: Text("This PDF doesn't include text form fields we can auto-fill.")
            )
        case .applying:
            progress("Applying suggestions…")
        case .done(let applied):
            ContentUnavailableView {
                Label("Form Filled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } description: {
                Text("Applied \(applied) suggestion\(applied == 1 ? "" : "s"). Close to see the updated PDF.")
            } actions: {
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
            }
        case .failed(let message):
            ContentUnavailableView(
                "Auto-Fill Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private func progress(_ message: String) -> some View {
        VStack(spacing: DesignSystem.Spacing.m) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewList: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Text("Review the suggestions, edit any that look off, and tap **Apply** to fill the form.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Fields") {
                    ForEach($filler.suggestions) { $suggestion in
                        SuggestionRow(suggestion: $suggestion)
                    }
                }
            }
            applyBar
        }
    }

    private var applyBar: some View {
        VStack(spacing: DesignSystem.Spacing.s) {
            Button {
                filler.apply(to: document.fileURL)
                onApplied()
            } label: {
                Text("Apply \(acceptedCount) Suggestion\(acceptedCount == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.s)
            }
            .buttonStyle(.glassProminent)
            .disabled(acceptedCount == 0)
        }
        .padding(DesignSystem.Spacing.l)
    }

    private var acceptedCount: Int {
        filler.suggestions.filter { $0.accepted && !$0.suggestedValue.isEmpty }.count
    }
}

private struct SuggestionRow: View {
    @Binding var suggestion: FormAutoFiller.FieldSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.s) {
                Toggle("", isOn: $suggestion.accepted)
                    .labelsHidden()
                    .toggleStyle(.switch)
                VStack(alignment: .leading) {
                    Text(suggestion.fieldName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Page \(suggestion.pageIndex + 1)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            TextField("Value", text: $suggestion.suggestedValue, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .disabled(!suggestion.accepted)
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }
}

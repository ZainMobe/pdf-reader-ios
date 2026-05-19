import SwiftUI

/// Sheet for streaming an on-device translation of the open document.
struct TranslateSheet: View {
    let document: Document
    @State private var translator = DocumentTranslator()
    @State private var selectedLanguage: TranslationLanguage = .spanish
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                languageBar
                Divider()
                ScrollView {
                    content
                        .padding(DesignSystem.Spacing.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Translate")
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
            .task(id: selectedLanguage) {
                translator.translate(document, to: selectedLanguage)
            }
            .onDisappear { translator.cancel() }
        }
    }

    private var languageBar: some View {
        HStack {
            Text("Translate to")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Language", selection: $selectedLanguage) {
                ForEach(TranslationLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            Spacer()
        }
        .padding(DesignSystem.Spacing.m)
    }

    @ViewBuilder
    private var content: some View {
        switch translator.state {
        case .idle, .loading:
            ProgressView("Translating to \(selectedLanguage.displayName)…")
                .frame(maxWidth: .infinity)
                .padding(.top, DesignSystem.Spacing.xxl)
        case .streaming(let text), .done(let text):
            Text(text)
                .font(.body)
                .textSelection(.enabled)
        case .failed(let message):
            ContentUnavailableView(
                "Translation failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}

import SwiftUI
import SwiftData
import PDFKit

/// Translate-PDF surface. Streams chunked translations into a generated PDF,
/// shows a PDFKit preview for review, and saves it as a new `Document` to
/// the library on confirm.
struct TranslateSheet: View {
    let document: Document
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var translator = DocumentTranslator()
    @State private var selectedLanguage: TranslationLanguage = .spanish
    @State private var languagePickerOpen = false
    @State private var savedDocumentTitle: String?
    @State private var didStartInitial = false

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient
                VStack(spacing: 0) {
                    languageBar
                    content
                }
            }
            .navigationTitle("Translate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task {
                if !didStartInitial {
                    didStartInitial = true
                    translator.translate(document, to: selectedLanguage)
                }
            }
            .onChange(of: selectedLanguage) { _, newLanguage in
                translator.translate(document, to: newLanguage)
            }
            .onDisappear {
                if savedDocumentTitle == nil {
                    translator.cancel()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.12), .clear],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }

    // MARK: - Language picker

    private var languageBar: some View {
        HStack(spacing: DesignSystem.Spacing.s) {
            Image(systemName: "character.bubble")
                .foregroundStyle(.tint)
            Text("Translate to")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(TranslationLanguage.allCases) { language in
                    Button {
                        if language != selectedLanguage {
                            Haptics.selection()
                            selectedLanguage = language
                        }
                    } label: {
                        if language == selectedLanguage {
                            Label("\(language.flag)  \(language.displayName)", systemImage: "checkmark")
                        } else {
                            Text("\(language.flag)  \(language.displayName)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedLanguage.flag)
                    Text(selectedLanguage.displayName)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, DesignSystem.Spacing.m)
                .padding(.vertical, 6)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            Spacer()
        }
        .padding(.horizontal, DesignSystem.Spacing.l)
        .padding(.vertical, DesignSystem.Spacing.s)
    }

    // MARK: - Content area

    @ViewBuilder
    private var content: some View {
        if let savedTitle = savedDocumentTitle {
            savedView(title: savedTitle)
        } else {
            switch translator.state {
            case .idle:
                progressBlock(
                    title: "Preparing translation…",
                    subtitle: nil,
                    progress: nil
                )
            case .extracting:
                progressBlock(
                    title: "Reading the original PDF…",
                    subtitle: "Detecting text regions to translate",
                    progress: nil
                )
            case .translating(let progress, let currentPage, let totalPages):
                progressBlock(
                    title: "Translating to \(selectedLanguage.displayName)",
                    subtitle: "Page \(currentPage) of \(totalPages)",
                    progress: progress
                )
            case .rendering:
                progressBlock(
                    title: "Building translated PDF…",
                    subtitle: "Preserving original layout",
                    progress: nil
                )
            case .ready(let url, let pageCount):
                readyView(url: url, pageCount: pageCount)
            case .failed(let message):
                failureView(message: message)
            }
        }
    }

    // MARK: - States

    private func progressBlock(title: String, subtitle: String?, progress: Double?) -> some View {
        VStack(spacing: DesignSystem.Spacing.l) {
            VStack(spacing: DesignSystem.Spacing.m) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0.05)],
                                center: .center,
                                startRadius: 4,
                                endRadius: 48
                            )
                        )
                        .frame(width: 88, height: 88)
                    Image(systemName: "character.bubble")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse, options: .repeat(.continuous))
                }
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let progress {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                        .frame(maxWidth: 260)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.top, DesignSystem.Spacing.xl)

            fidelityHint
            Spacer()
        }
        .padding(DesignSystem.Spacing.l)
    }

    /// Subtle reassurance that the layout, images, and tables come along for
    /// the ride — the translator preserves them visually.
    private var fidelityHint: some View {
        HStack(spacing: DesignSystem.Spacing.s) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.subheadline)
                .foregroundStyle(.tint)
            Text("Layout, images, and tables are preserved from the original PDF.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignSystem.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
    }

    private func readyView(url: URL, pageCount: Int) -> some View {
        VStack(spacing: 0) {
            metadataPill(pageCount: pageCount)
                .padding(.horizontal, DesignSystem.Spacing.l)
                .padding(.top, DesignSystem.Spacing.s)
            TranslatedPreview(url: url)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.medium))
                .padding(.horizontal, DesignSystem.Spacing.l)
                .padding(.top, DesignSystem.Spacing.s)
            saveBar
        }
    }

    private func metadataPill(pageCount: Int) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text("Translated PDF ready · \(pageCount) page\(pageCount == 1 ? "" : "s")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, DesignSystem.Spacing.m)
        .padding(.vertical, DesignSystem.Spacing.s)
        .glassEffect(.regular, in: .capsule)
    }

    private var saveBar: some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            Button {
                Haptics.selection()
                translator.cancel()
                translator.translate(document, to: selectedLanguage)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.s)
            }
            .buttonStyle(.glass)

            Button {
                save()
            } label: {
                Label("Save to Library", systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.s)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(DesignSystem.Spacing.l)
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: DesignSystem.Spacing.l) {
            ContentUnavailableView(
                "Translation failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            Button("Try Again") {
                Haptics.impact(.light)
                translator.translate(document, to: selectedLanguage)
            }
            .buttonStyle(.glassProminent)
            Spacer()
        }
    }

    private func savedView(title: String) -> some View {
        VStack(spacing: DesignSystem.Spacing.l) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: title)
            }
            VStack(spacing: DesignSystem.Spacing.xs) {
                Text("Saved to Library")
                    .font(.title2.weight(.bold))
                Text("\u{201C}\(title)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .frame(maxWidth: 240)
                    .padding(.vertical, DesignSystem.Spacing.s)
            }
            .buttonStyle(.glassProminent)
            Spacer()
        }
        .padding(.top, DesignSystem.Spacing.xxl)
        .padding(DesignSystem.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func save() {
        guard let saved = translator.saveToLibrary(
            sourceDocument: document,
            language: selectedLanguage,
            in: modelContext
        ) else { return }
        Haptics.success()
        savedDocumentTitle = saved.title
    }
}

/// Lightweight PDFKit preview used in the review step. Read-only, non-editable.
private struct TranslatedPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

import PDFKit
import SwiftUI

/// Text-only reading mode: the document's text reflowed into a scrollable
/// column with adjustable type. Built for phones, where a fixed A4 layout
/// means constant pinch-and-pan.
///
/// Paragraphs are rebuilt from the PDF's line breaks; scanned documents
/// fall back to their OCR text. Tapping a page marker jumps back to that
/// page in the PDF view.
struct ReflowReaderView: View {
    let document: Document
    var startPage: Int = 0
    var onOpenPage: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReaderTheme.storageKey) private var themeRaw: String = ReaderTheme.light.rawValue
    @AppStorage("settings.reflowFontSize") private var fontSize: Double = 18
    @AppStorage("settings.reflowSerif") private var useSerif = false
    @AppStorage("settings.reflowLineSpacing") private var lineSpacing: Double = 6

    @State private var pages: [PageText] = []
    @State private var isLoading = true
    @State private var showingTypeControls = false

    struct PageText: Identifiable {
        let id: Int
        let paragraphs: [String]
    }

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .light }

    private var textColor: Color {
        switch theme {
        case .light: Color(uiColor: .label)
        case .sepia: Color(red: 0.24, green: 0.18, blue: 0.10)
        case .dim: Color(white: 0.82)
        case .dark: Color(white: 0.92)
        }
    }

    private var background: Color {
        switch theme {
        case .light: Color(uiColor: .systemBackground)
        case .sepia: Color(red: 0.97, green: 0.93, blue: 0.84)
        case .dim: Color(white: 0.16)
        case .dark: Color(white: 0.05)
        }
    }

    private var font: Font {
        useSerif ? .system(size: fontSize, design: .serif) : .system(size: fontSize)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Preparing text…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pages.isEmpty {
                    ContentUnavailableView(
                        "No Text Found",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("This looks like a scanned document without a text layer. Use Tools > Images to PDF with OCR, or Scan to PDF, to make it readable here.")
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.l) {
                                ForEach(pages) { page in
                                    pageMarker(page.id)
                                        .id(page.id)
                                    ForEach(Array(page.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                        Text(paragraph)
                                            .font(font)
                                            .lineSpacing(lineSpacing)
                                            .foregroundStyle(textColor)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(.horizontal, DesignSystem.Spacing.xl)
                            .padding(.vertical, DesignSystem.Spacing.xl)
                            .frame(maxWidth: 720)
                            .frame(maxWidth: .infinity)
                        }
                        .onAppear {
                            if startPage > 0 { proxy.scrollTo(startPage, anchor: .top) }
                        }
                    }
                }
            }
            .background(background.ignoresSafeArea())
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(theme.prefersDarkChrome ? .dark : nil)
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingTypeControls.toggle()
                    } label: {
                        Label("Text Size", systemImage: "textformat.size")
                    }
                    .popover(isPresented: $showingTypeControls) {
                        typeControls
                            .presentationCompactAdaptation(.popover)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Theme", selection: $themeRaw) {
                            ForEach(ReaderTheme.allCases) { t in
                                Label(t.title, systemImage: t.systemImage).tag(t.rawValue)
                            }
                        }
                    } label: {
                        Label("Theme", systemImage: theme.systemImage)
                    }
                }
            }
            .task { await load() }
        }
    }

    private func pageMarker(_ index: Int) -> some View {
        Button {
            onOpenPage(index)
            dismiss()
        } label: {
            HStack {
                Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
                Text("Page \(index + 1)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(index + 1). Open in PDF view.")
    }

    private var typeControls: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.l) {
            HStack {
                Text("A").font(.system(size: 13))
                Slider(value: $fontSize, in: 13...32, step: 1)
                Text("A").font(.system(size: 24))
            }
            Picker("Font", selection: $useSerif) {
                Text("Sans").tag(false)
                Text("Serif").font(.system(.body, design: .serif)).tag(true)
            }
            .pickerStyle(.segmented)
            HStack {
                Image(systemName: "text.alignleft")
                Slider(value: $lineSpacing, in: 0...14, step: 1)
                Image(systemName: "text.justify.leading")
            }
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 280)
    }

    private func load() async {
        let url = document.fileURL
        let ocrFallback = document.ocrText
        await DocumentStorage.ensureDownloaded(at: url)
        let result = await Task.detached(priority: .userInitiated) { () -> [PageText] in
            guard let pdf = PDFDocument.opened(at: url), !pdf.isLocked else { return [] }
            var out: [PageText] = []
            for i in 0..<pdf.pageCount {
                let raw = pdf.page(at: i)?.string ?? ""
                let normalized = PDFExport.normalizeParagraphs(raw)
                let paragraphs = normalized.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if !paragraphs.isEmpty { out.append(PageText(id: i, paragraphs: paragraphs)) }
            }
            if out.isEmpty, let ocr = ocrFallback?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                let paragraphs = PDFExport.normalizeParagraphs(ocr).components(separatedBy: "\n\n")
                out = [PageText(id: 0, paragraphs: paragraphs)]
            }
            return out
        }.value
        pages = result
        isLoading = false
    }
}

import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Tool sheet: export a PDF's text as an editable Word document or plain
/// text file. Paragraphs are rebuilt from the text layer; scanned pages
/// without text are embedded as images in Word so nothing goes missing.
///
/// On success the form is replaced by `ExportResultView`: a clear done state
/// with a QuickLook preview of the exported file and Share / Save to Files.
struct PDFToWordView: View {
    @Environment(\.dismiss) private var dismiss

    enum Format: String, CaseIterable, Identifiable {
        case word, text
        var id: Self { self }
        var title: String { self == .word ? "Word (.docx)" : "Plain text (.txt)" }
        var fileExtension: String { self == .word ? "docx" : "txt" }
        var systemImage: String { self == .word ? "doc.richtext" : "doc.plaintext" }
        var resultTitle: String { self == .word ? "Word Document Ready" : "Text File Ready" }
    }

    @State private var selectedDoc: Document?
    @State private var format: Format = .word
    @State private var embedScans = true
    @State private var isWorking = false
    @State private var error: String?
    @State private var result: ExportResult?
    /// Directory holding the last export, removed when replaced or on dismiss.
    @State private var outputDirectory: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    ExportResultView(
                        result: result,
                        onDone: { dismiss() },
                        onExportAnother: { self.result = nil }
                    )
                } else {
                    formContent
                }
            }
            .navigationTitle(result == nil ? "PDF to Word" : "Done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if result != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }.disabled(isWorking)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Export") { export() }
                            .buttonStyle(.glassProminent)
                            .disabled(selectedDoc == nil || isWorking)
                    }
                }
            }
            .overlay {
                if isWorking {
                    VStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView()
                        Text(format == .word ? "Building Word document…" : "Extracting text…")
                            .font(.subheadline)
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
                }
            }
            .alert("Couldn't export", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .onDisappear {
                // Exports live in a per-run temp directory; Share and Save to
                // Files both copy, so it's safe to remove once the sheet closes.
                if let outputDirectory { try? FileManager.default.removeItem(at: outputDirectory) }
            }
        }
    }

    private var formContent: some View {
        Form {
            SourceDocumentSection(selected: $selectedDoc)

            Section("Export as") {
                ForEach(Format.allCases) { f in
                    Button {
                        format = f
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.m) {
                            Image(systemName: format == f ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(.tint)
                            Label(f.title, systemImage: f.systemImage)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                if format == .word {
                    Toggle("Include scanned pages as images", isOn: $embedScans)
                }
            }

            Section {
                Text(format == .word
                     ? "Headings, fonts, bold and italic, colours, alignment, lists, images and graphics are carried into an editable Word document with the original page size. Complex tables may come through as tab-aligned text."
                     : "Text from every page, separated by blank lines. For scanned PDFs, the OCR text from Scan to PDF is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func export() {
        guard let doc = selectedDoc else { return }
        let url = doc.fileURL
        let isWord = format == .word
        let ext = format.fileExtension
        let embed = embedScans
        let baseName = DocumentStorage.sanitizedTitle(doc.title)
        let ocrFallback = doc.ocrText
        let pageCount = doc.pageCount
        let resultTitle = format.resultTitle
        isWorking = true

        Task {
            defer { isWorking = false }
            await DocumentStorage.ensureDownloaded(at: url)
            do {
                let output: (file: URL, dir: URL, excerpt: String?) = try await Task.detached(priority: .userInitiated) {
                    guard let pdf = PDFDocument.opened(at: url) else { throw PDFOperations.OpError.noSourceDocument }
                    let dir = FileManager.default.temporaryDirectory.appending(path: "PDFToWord-\(UUID().uuidString)", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let file = dir.appending(path: "\(baseName).\(ext)")
                    if isWord {
                        var options = PDFExport.WordOptions()
                        options.embedImagesForScannedPages = embed
                        let data = try PDFExport.docx(from: pdf, title: baseName, options: options)
                        try data.write(to: file, options: [.atomic])
                        let preview = try? PDFExport.text(from: pdf, fallbackOCR: ocrFallback)
                        return (file, dir, preview.map { String($0.prefix(600)) })
                    } else {
                        let text = try PDFExport.text(from: pdf, fallbackOCR: ocrFallback)
                        try text.write(to: file, atomically: true, encoding: .utf8)
                        return (file, dir, String(text.prefix(600)))
                    }
                }.value

                if let old = outputDirectory { try? FileManager.default.removeItem(at: old) }
                outputDirectory = output.dir
                let size = ByteCountFormatter.string(
                    fromByteCount: (try? FileManager.default.attributesOfItem(atPath: output.file.path)[.size] as? Int64) ?? 0,
                    countStyle: .file
                )
                result = ExportResult(
                    title: resultTitle,
                    summary: "\(pageCount) \(pageCount == 1 ? "page" : "pages") from \u{201C}\(doc.title)\u{201D} · \(size)",
                    files: [output.file],
                    textExcerpt: isWord ? nil : output.excerpt
                )
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

import PDFKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Tool sheet: export a PDF's text as an editable Word document or plain
/// text file. Paragraphs are rebuilt from the text layer; scanned pages
/// without text are embedded as images in Word so nothing goes missing.
struct PDFToWordView: View {
    @Environment(\.dismiss) private var dismiss

    enum Format: String, CaseIterable, Identifiable {
        case word, text
        var id: Self { self }
        var title: String { self == .word ? "Word (.docx)" : "Plain text (.txt)" }
        var fileExtension: String { self == .word ? "docx" : "txt" }
        var systemImage: String { self == .word ? "doc.richtext" : "doc.plaintext" }
    }

    @State private var selectedDoc: Document?
    @State private var format: Format = .word
    @State private var embedScans = true
    @State private var isWorking = false
    @State private var error: String?
    @State private var exported: URL?
    @State private var textPreview: String?
    @State private var showingShare = false

    var body: some View {
        NavigationStack {
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
                         ? "Text and paragraphs become editable in Word, Pages or Google Docs. Fonts, columns and exact positioning aren't preserved."
                         : "Text from every page, separated by blank lines. For scanned PDFs, the OCR text from Scan to PDF is used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let exported {
                    Section("Result") {
                        HStack(spacing: DesignSystem.Spacing.m) {
                            Image(systemName: format.systemImage)
                                .font(.title2)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exported.lastPathComponent).lineLimit(2)
                                Text(ByteCountFormatter.string(fromByteCount: fileSize(exported), countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        Button {
                            showingShare = true
                        } label: {
                            Label("Share or Save to Files", systemImage: "square.and.arrow.up")
                        }
                        if let textPreview {
                            DisclosureGroup("Preview") {
                                Text(textPreview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle("PDF to Word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(exported == nil ? "Cancel" : "Done") { dismiss() }.disabled(isWorking)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(exported == nil ? "Export" : "Export Again") { export() }
                        .buttonStyle(.glassProminent)
                        .disabled(selectedDoc == nil || isWorking)
                }
            }
            .overlay {
                if isWorking {
                    VStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView()
                        Text("Extracting text…").font(.subheadline)
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
                }
            }
            .sheet(isPresented: $showingShare) {
                if let exported {
                    ActivityShareSheet(items: [exported])
                        .presentationDetents([.medium, .large])
                }
            }
            .alert("Couldn't export", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .onChange(of: selectedDoc) { _, _ in exported = nil; textPreview = nil }
            .onChange(of: format) { _, _ in exported = nil; textPreview = nil }
            .onDisappear {
                // The export lives in a per-run temp directory; clean it up.
                if let exported { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
            }
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func export() {
        guard let doc = selectedDoc else { return }
        let url = doc.fileURL
        let isWord = format == .word
        let ext = format.fileExtension
        let embed = embedScans
        let baseName = DocumentStorage.sanitizedTitle(doc.title)
        let ocrFallback = doc.ocrText
        isWorking = true

        Task {
            defer { isWorking = false }
            await DocumentStorage.ensureDownloaded(at: url)
            do {
                let result: (URL, String?) = try await Task.detached(priority: .userInitiated) {
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
                        return (file, preview.map { String($0.prefix(600)) })
                    } else {
                        let text = try PDFExport.text(from: pdf, fallbackOCR: ocrFallback)
                        try text.write(to: file, atomically: true, encoding: .utf8)
                        return (file, String(text.prefix(600)) as String?)
                    }
                }.value
                if let old = exported { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
                exported = result.0
                textPreview = result.1
                EntitlementStore.shared.recordUse(.tool)
                Haptics.success()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

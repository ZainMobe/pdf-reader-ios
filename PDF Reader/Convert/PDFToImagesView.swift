import PDFKit
import Photos
import SwiftData
import SwiftUI

/// Tool sheet: export PDF pages as JPEG or PNG, to Photos or via the share
/// sheet (which includes Save to Files). Pages render one at a time.
struct PDFToImagesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDoc: Document?
    @State private var format: PDFExport.ImageFormat = .jpeg
    @State private var resolution: PDFExport.Resolution = .screen
    @State private var allPages = true
    @State private var rangeText = ""
    @State private var destination: Destination = .photos

    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var progressText = ""
    @State private var error: String?
    /// Set on success; replaces the form with a preview + share screen.
    @State private var result: ExportResult?
    /// Temp directory holding the rendered images; removed when replaced
    /// or when the sheet closes (Share, Files and Photos all copy).
    @State private var outputDirectory: URL?
    @State private var photosMessage: String?

    enum Destination: String, CaseIterable, Identifiable {
        case photos, share
        var id: Self { self }
        var title: String { self == .photos ? "Save to Photos" : "Share / Files" }
    }

    private var pageCount: Int { selectedDoc?.pageCount ?? 0 }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    ExportResultView(
                        result: result,
                        onDone: { dismiss() },
                        onExportAnother: { self.result = nil },
                        secondaryAction: .init(title: "Save to Photos", systemImage: "photo.on.rectangle") {
                            saveToPhotos(result.files)
                        }
                    )
                } else {
                    formContent
                }
            }
            .navigationTitle(result == nil ? "PDF to Images" : "Done")
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
                            .disabled(selectedDoc == nil || isWorking || (!allPages && rangeText.isEmpty))
                    }
                }
            }
            .overlay {
                if isWorking {
                    VStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView(value: progress)
                            .frame(width: 160)
                        Text(progressText).font(.subheadline)
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
                }
            }
            .alert("Saved to Photos", isPresented: Binding(
                get: { photosMessage != nil }, set: { if !$0 { photosMessage = nil } }
            )) {
                Button("OK") { photosMessage = nil }
            } message: {
                Text(photosMessage ?? "")
            }
            .alert("Couldn't export", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .onDisappear {
                if let outputDirectory { try? FileManager.default.removeItem(at: outputDirectory) }
            }
        }
    }

    private var formContent: some View {
            Form {
                SourceDocumentSection(selected: $selectedDoc)

                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(PDFExport.ImageFormat.allCases) { f in Text(f.title).tag(f) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Resolution", selection: $resolution) {
                        ForEach(PDFExport.Resolution.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    Text(resolution.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Pages") {
                    Toggle("All pages", isOn: $allPages)
                    if !allPages {
                        TextField("e.g. 1-3, 5, 8", text: $rangeText)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                    }
                    if let selectedDoc {
                        Text(allPages
                             ? "\(selectedDoc.pageCount) \(selectedDoc.pageCount == 1 ? "image" : "images") will be created."
                             : rangeSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Destination") {
                    Picker("Destination", selection: $destination) {
                        ForEach(Destination.allCases) { d in Text(d.title).tag(d) }
                    }
                    .pickerStyle(.segmented)
                    Text(destination == .photos
                         ? "Images are added to your photo library in page order. You can still share or save them to Files afterwards."
                         : "Preview the images, then choose Share, Save to Files or Save to Photos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private var rangeSummary: String {
        guard pageCount > 0 else { return "" }
        do {
            let pages = try PageRange.parse(rangeText, pageCount: pageCount)
            return "\(PageRange.describe(pages)) · \(pages.count) \(pages.count == 1 ? "image" : "images")"
        } catch {
            return rangeText.isEmpty ? "Enter pages to export." : error.localizedDescription
        }
    }

    // MARK: - Export

    private func export() {
        guard let doc = selectedDoc else { return }
        let url = doc.fileURL
        let indices: [Int]
        do {
            indices = try allPages
                ? Array(0..<max(doc.pageCount, 0))
                : PageRange.parse(rangeText, pageCount: doc.pageCount)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let fmt = format, dpi = resolution.dpi, dest = destination
        let baseName = DocumentStorage.sanitizedTitle(doc.title)
        isWorking = true
        progress = 0
        progressText = "Preparing…"

        Task {
            defer { isWorking = false }
            await DocumentStorage.ensureDownloaded(at: url)
            guard let pdf = PDFDocument.opened(at: url) else {
                error = "The PDF couldn't be opened."
                return
            }
            if pdf.isLocked { error = PDFExport.ExportError.locked.localizedDescription; return }
            let total = indices.count
            guard total > 0 else { error = PDFExport.ExportError.noPages.localizedDescription; return }

            if dest == .photos {
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    error = "Allow PDF Editor to add photos in Settings, or choose Share / Files instead."
                    return
                }
            }

            let dir = FileManager.default.temporaryDirectory.appending(path: "PDFToImages-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var written: [URL] = []
            let digits = String(pdf.pageCount).count

            for (n, index) in indices.enumerated() {
                progressText = "Rendering page \(index + 1) of \(pdf.pageCount)…"
                progress = Double(n) / Double(total)
                guard let page = pdf.page(at: index) else { continue }
                let data = await Task.detached(priority: .userInitiated) {
                    PDFExport.imageData(for: page, format: fmt, dpi: dpi)
                }.value
                guard let data else { continue }
                let number = String(format: "%0\(digits)d", index + 1)
                let file = dir.appending(path: "\(baseName) - \(number).\(fmt.fileExtension)")
                do { try data.write(to: file, options: [.atomic]) } catch { continue }
                written.append(file)
                await Task.yield()
            }
            progress = 1

            guard !written.isEmpty else {
                try? FileManager.default.removeItem(at: dir)
                error = "No pages could be rendered."
                return
            }
            if let old = outputDirectory { try? FileManager.default.removeItem(at: old) }
            outputDirectory = dir

            let count = written.count
            let noun = count == 1 ? "image" : "images"
            var summary = "\(count) \(fmt.title) \(noun) from \u{201C}\(doc.title)\u{201D} at \(Int(dpi)) DPI"
            if written.count < total {
                summary += " (\(total - written.count) \(total - written.count == 1 ? "page" : "pages") couldn't be rendered)"
            }

            if dest == .photos {
                progressText = "Saving to Photos…"
                do {
                    try await addToPhotos(written)
                    summary = "Added to your photo library · " + summary
                } catch {
                    // Still show the result so the user can share or save
                    // the images another way instead of losing them.
                    summary += ". Photos didn't accept them: \(error.localizedDescription)"
                }
            }

            // The result view records the free-tier use on appear.
            result = ExportResult(title: "Images Ready", summary: summary, files: written)
        }
    }

    /// "Save to Photos" from the result screen (Share destination).
    private func saveToPhotos(_ files: [URL]) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                error = "Allow PDF Editor to add photos in Settings, or use Share / Save to Files instead."
                return
            }
            do {
                try await addToPhotos(files)
                Haptics.success()
                photosMessage = "\(files.count) \(files.count == 1 ? "image" : "images") added to your photo library."
            } catch {
                self.error = "Photos didn't accept the images: \(error.localizedDescription)"
            }
        }
    }

    private func addToPhotos(_ files: [URL]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for file in files {
                _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
            }
        }
    }
}

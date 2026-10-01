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
    @State private var shareItems: [URL]?
    @State private var doneMessage: String?

    enum Destination: String, CaseIterable, Identifiable {
        case photos, share
        var id: Self { self }
        var title: String { self == .photos ? "Save to Photos" : "Share / Files" }
    }

    private var pageCount: Int { selectedDoc?.pageCount ?? 0 }

    var body: some View {
        NavigationStack {
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
                         ? "Images are added to your photo library in page order."
                         : "Choose Save to Files, AirDrop, or any app from the share sheet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PDF to Images")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export") { export() }
                        .buttonStyle(.glassProminent)
                        .disabled(selectedDoc == nil || isWorking || (!allPages && rangeText.isEmpty))
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
            .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
                if let shareItems {
                    ActivityShareSheet(items: shareItems)
                        .presentationDetents([.medium, .large])
                }
            }
            .alert("Saved to Photos", isPresented: Binding(
                get: { doneMessage != nil }, set: { if !$0 { doneMessage = nil } }
            )) {
                Button("Done") { dismiss() }
                Button("Export More", role: .cancel) { doneMessage = nil }
            } message: {
                Text(doneMessage ?? "")
            }
            .alert("Couldn't export", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
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
                error = "No pages could be rendered."
                return
            }
            EntitlementStore.shared.recordUse(.tool)

            switch dest {
            case .share:
                Haptics.success()
                shareItems = written
            case .photos:
                progressText = "Saving to Photos…"
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        for file in written {
                            _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
                        }
                    }
                    Haptics.success()
                    doneMessage = "\(written.count) \(written.count == 1 ? "image" : "images") added to your photo library."
                } catch {
                    self.error = "Photos didn't accept the images: \(error.localizedDescription)"
                }
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }
}

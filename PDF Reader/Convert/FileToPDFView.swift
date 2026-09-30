import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Tool sheet: convert Word, Excel, PowerPoint, Pages, Numbers, Keynote,
/// RTF, text, Markdown and HTML files, or any web page, into a PDF in the
/// Library. Everything runs on device.
struct FileToPDFView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case file, web
        var id: Self { self }
        var title: String { self == .file ? "File" : "Web page" }
    }

    @State private var mode: Mode = .file
    @State private var pickedFile: URL?
    @State private var pickedFileName = ""
    @State private var pickedFileSize: Int64 = 0
    @State private var showingImporter = false
    @State private var urlText = ""
    @State private var paper: Paper = .letter
    @State private var title = ""

    @State private var isWorking = false
    @State private var progressText = ""
    @State private var error: String?
    @State private var success: ToolSuccessResult?
    @State private var note: String?

    enum Paper: String, CaseIterable, Identifiable {
        case letter, a4
        var id: Self { self }
        var title: String { self == .letter ? "US Letter" : "A4" }
        var setup: DocumentToPDF.PageSetup { self == .letter ? .letter : .a4 }
    }

    private var canConvert: Bool {
        switch mode {
        case .file: return pickedFile != nil
        case .web: return normalizedURL != nil
        }
    }

    /// Accepts "example.com/report" as well as full URLs.
    private var normalizedURL: URL? {
        var text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), let host = url.host(), host.contains(".") else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            Group {
                if let success {
                    ToolSuccessView(result: success) { dismiss() }
                } else {
                    formContent
                }
            }
            .navigationTitle(success == nil ? "File to PDF" : "Done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if success != nil {
                    ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }.disabled(isWorking)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Convert") { convert() }
                            .buttonStyle(.glassProminent)
                            .disabled(!canConvert || isWorking)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: DocumentToPDF.supportedTypes,
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first { stage(url) }
            }
            .overlay {
                if isWorking {
                    VStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView()
                        Text(progressText).font(.subheadline)
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
                }
            }
            .alert("Couldn't convert", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .onDisappear {
                if let pickedFile { try? FileManager.default.removeItem(at: pickedFile) }
            }
        }
    }

    private var formContent: some View {
        Form {
            Section {
                Picker("Source", selection: $mode) {
                    ForEach(Mode.allCases) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.segmented)
            }

            switch mode {
            case .file:
                Section {
                    if let _ = pickedFile {
                        HStack(spacing: DesignSystem.Spacing.m) {
                            Image(systemName: icon(for: pickedFileName))
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pickedFileName).lineLimit(2)
                                Text(ByteCountFormatter.string(fromByteCount: pickedFileSize, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Change") { showingImporter = true }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                        }
                    } else {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Choose a file", systemImage: "doc.badge.plus")
                        }
                    }
                } header: {
                    Text("File")
                } footer: {
                    Text("Word, Excel, PowerPoint, Pages, Numbers, Keynote, RTF, text, Markdown, CSV and HTML.")
                }

            case .web:
                Section {
                    TextField("example.com/article", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .submitLabel(.go)
                        .onSubmit { if canConvert { convert() } }
                    if urlText.isEmpty {
                        // PasteButton reads the clipboard only on tap, so no
                        // "pasted from" prompt appears just for opening the tool.
                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first { urlText = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                } header: {
                    Text("Web address")
                } footer: {
                    Text("The page is loaded once, paginated, and saved as a PDF you can annotate offline. Pages behind a login can't be captured.")
                }
            }

            Section("Paper") {
                Picker("Paper", selection: $paper) {
                    ForEach(Paper.allCases) { p in Text(p.title).tag(p) }
                }
                .pickerStyle(.segmented)
            }

            Section("Title") {
                TextField(mode == .file ? pickedFileName.isEmpty ? "Title" : titleWithoutExtension : "Page title", text: $title)
                    .textInputAutocapitalization(.words)
            }
        }
    }

    private var titleWithoutExtension: String {
        (pickedFileName as NSString).deletingPathExtension
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "docx", "doc", "pages", "rtf", "rtfd": "doc.text"
        case "xlsx", "xls", "numbers", "csv": "tablecells"
        case "pptx", "ppt", "key": "rectangle.on.rectangle"
        case "html", "htm": "globe"
        case "md", "markdown": "text.alignleft"
        default: "doc"
        }
    }

    // MARK: - Actions

    /// Copies the picked file into temp so WebKit can read it without a
    /// security scope and so we can hand a stable URL around.
    private func stage(_ source: URL) {
        let didStart = source.startAccessingSecurityScopedResource()
        defer { if didStart { source.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appending(path: "FileToPDF", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Keep the original name: WebKit picks the document preview by extension.
        let destination = dir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: source.lastPathComponent)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            var coordinatorError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordinatorError) { readable in
                do { try FileManager.default.copyItem(at: readable, to: destination) } catch { copyError = error }
            }
            if let coordinatorError { throw coordinatorError }
            if let copyError { throw copyError }
        } catch {
            self.error = "Couldn't read that file: \(error.localizedDescription)"
            return
        }
        if let old = pickedFile { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
        pickedFile = destination
        pickedFileName = source.lastPathComponent
        pickedFileSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        if title.isEmpty { title = (source.lastPathComponent as NSString).deletingPathExtension }
    }

    private func convert() {
        let source: DocumentToPDF.Source
        switch mode {
        case .file:
            guard let pickedFile else { return }
            source = .file(pickedFile)
            progressText = "Rendering \(pickedFileName)…"
        case .web:
            guard let url = normalizedURL else { return }
            source = .web(url)
            progressText = "Loading \(url.host() ?? "page")…"
        }
        let setup = paper.setup
        isWorking = true

        Task {
            defer { isWorking = false }
            do {
                let output = try await DocumentToPDF.convert(source, page: setup)
                let finalTitle = DocumentStorage.sanitizedTitle(
                    title.isEmpty ? output.title : title,
                    fallback: mode == .web ? "Web page" : "Document"
                )
                let temp = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
                try output.data.write(to: temp, options: [.atomic])
                let doc = try DocumentStorage.adoptGeneratedPDF(at: temp, title: finalTitle, into: modelContext)
                try? modelContext.save()
                var summary = "\(output.pageCount) \(output.pageCount == 1 ? "page" : "pages")"
                if let note = output.note { summary += ". " + note }
                success = ToolSuccessResult(title: "PDF Created", summary: summary, documents: [doc])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

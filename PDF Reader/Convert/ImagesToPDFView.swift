import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Tool sheet: pick photos or image files, arrange them, and build one PDF.
///
/// Images are never held at full resolution: each pick is written to a
/// temp file and only a small thumbnail lives in memory. Reordering is
/// drag and drop on the grid; long-press for rotate and remove.
struct ImagesToPDFView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var pages: [PickedImage] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingFilesImporter = false
    @State private var isLoadingPicks = false
    @State private var loadingCount = 0

    @State private var title = "Images · " + Date.now.formatted(date: .abbreviated, time: .shortened)
    @State private var pageSize: ImagesToPDF.PageSize = .fitImage
    @State private var quality: Quality = .balanced
    @State private var makeSearchable = false

    @State private var isWorking = false
    @State private var progressText = ""
    @State private var error: String?
    @State private var success: ToolSuccessResult?
    @State private var draggingID: UUID?

    static let maxImages = 50

    struct PickedImage: Identifiable, Equatable {
        let id = UUID()
        var url: URL
        var thumbnail: UIImage
        var quarterTurns: Int = 0
        var name: String
    }

    enum Quality: String, CaseIterable, Identifiable {
        case small, balanced, best
        var id: Self { self }
        var title: String {
            switch self {
            case .small: "Smaller file"
            case .balanced: "Balanced"
            case .best: "Best quality"
            }
        }
        var jpegQuality: CGFloat {
            switch self {
            case .small: 0.6
            case .balanced: 0.82
            case .best: 0.95
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: DesignSystem.Spacing.m)]

    var body: some View {
        NavigationStack {
            Group {
                if let success {
                    ToolSuccessView(result: success) { dismiss() }
                } else if pages.isEmpty && !isLoadingPicks {
                    emptyState
                } else {
                    formContent
                }
            }
            .navigationTitle(success == nil ? "Images to PDF" : "Done")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if success != nil {
                    ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }.disabled(isWorking)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(pages.count > 1 ? "Create (\(pages.count))" : "Create") { convert() }
                            .buttonStyle(.glassProminent)
                            .disabled(pages.isEmpty || isWorking || isLoadingPicks)
                    }
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                loadPhotoItems(items)
            }
            .fileImporter(
                isPresented: $showingFilesImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { loadFileURLs(urls) }
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
            .alert("Couldn't create PDF", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .onDisappear { cleanupTemp() }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            VStack(spacing: DesignSystem.Spacing.s) {
                Text("Turn photos into a PDF")
                    .font(.title3.weight(.semibold))
                Text("Pick up to \(Self.maxImages) images. HEIC, JPEG, PNG and screenshots all work. Reorder, rotate, and optionally make the text searchable.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            VStack(spacing: DesignSystem.Spacing.m) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: Self.maxImages, matching: .images) {
                    Label("Choose from Photos", systemImage: "photo.stack")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.Spacing.m)
                }
                .buttonStyle(.glassProminent)
                Button {
                    showingFilesImporter = true
                } label: {
                    Label("Browse Files", systemImage: "folder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.Spacing.m)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            Spacer()
            Spacer()
        }
    }

    // MARK: - Form

    private var formContent: some View {
        Form {
            Section {
                LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.m) {
                    ForEach(pages) { page in
                        pageCell(page)
                    }
                    addMoreCell
                }
                .padding(.vertical, DesignSystem.Spacing.s)
                .animation(.snappy, value: pages)
                .onChange(of: pages) { _, _ in draggingID = nil }
            } header: {
                HStack {
                    Text(pages.count == 1 ? "1 page" : "\(pages.count) pages")
                    if isLoadingPicks {
                        ProgressView().controlSize(.mini)
                        Text("Adding \(loadingCount)…")
                    }
                }
            } footer: {
                Text("Drag to reorder. Long-press a page to rotate or remove it.")
            }

            Section("Title") {
                TextField("Title", text: $title)
                    .textInputAutocapitalization(.words)
            }

            Section("Page size") {
                Picker("Page size", selection: $pageSize) {
                    ForEach(ImagesToPDF.PageSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                Text(pageSize == .fitImage
                     ? "Each page matches its image with no borders."
                     : "Images are centred on \(pageSize.title) pages; landscape photos get landscape pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quality") {
                Picker("Quality", selection: $quality) {
                    ForEach(Quality.allCases) { q in Text(q.title).tag(q) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle(isOn: $makeSearchable) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Make text searchable")
                        Text("Runs on-device OCR so you can search, copy and highlight text in the photos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func pageCell(_ page: PickedImage) -> some View {
        let index = pages.firstIndex(of: page) ?? 0
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
            Image(uiImage: page.thumbnail)
                .resizable()
                .scaledToFit()
                .rotationEffect(.degrees(Double(page.quarterTurns) * 90))
                .padding(6)
            Text("\(index + 1)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.tint))
                .padding(6)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .opacity(draggingID == page.id ? 0.4 : 1)
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: DesignSystem.Radius.small))
        .draggable(page.id.uuidString) {
            Image(uiImage: page.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 100)
                .onAppear { draggingID = page.id }
                .onDisappear { draggingID = nil }
        }
        .dropDestination(for: String.self) { ids, _ in
            defer { draggingID = nil }
            guard let idString = ids.first, let id = UUID(uuidString: idString) else { return false }
            move(id, before: page.id)
            return true
        }
        .contextMenu {
            Button { rotate(page, by: 1) } label: { Label("Rotate Right", systemImage: "rotate.right") }
            Button { rotate(page, by: -1) } label: { Label("Rotate Left", systemImage: "rotate.left") }
            Divider()
            Button(role: .destructive) { remove(page) } label: { Label("Remove", systemImage: "trash") }
        }
        .accessibilityLabel("Page \(index + 1), \(page.name)")
    }

    private var addMoreCell: some View {
        Group {
            PhotosPicker(selection: $photoItems, maxSelectionCount: max(1, Self.maxImages - pages.count), matching: .images) {
                addTile("Photos", systemImage: "photo.stack")
            }
            Button {
                showingFilesImporter = true
            } label: {
                addTile("Files", systemImage: "folder")
            }
            .buttonStyle(.plain)
        }
        .disabled(pages.count >= Self.maxImages)
    }

    private func addTile(_ title: String, systemImage: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption)
            }
            .foregroundStyle(.tint)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
    }

    // MARK: - Editing

    private func move(_ id: UUID, before targetID: UUID) {
        guard id != targetID,
              let from = pages.firstIndex(where: { $0.id == id }),
              let to = pages.firstIndex(where: { $0.id == targetID }) else { return }
        // After removal the target keeps its index when dragging backwards and
        // shifts left by one when dragging forwards; inserting at `to` puts
        // the dragged page exactly where the user dropped it either way.
        let item = pages.remove(at: from)
        pages.insert(item, at: min(to, pages.count))
        Haptics.selection()
    }

    private func rotate(_ page: PickedImage, by turns: Int) {
        guard let i = pages.firstIndex(of: page) else { return }
        pages[i].quarterTurns = ((pages[i].quarterTurns + turns) % 4 + 4) % 4
        Haptics.selection()
    }

    private func remove(_ page: PickedImage) {
        pages.removeAll { $0.id == page.id }
        try? FileManager.default.removeItem(at: page.url)
    }

    // MARK: - Loading

    private static let tempDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ImagesToPDF", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func cleanupTemp() {
        for page in pages { try? FileManager.default.removeItem(at: page.url) }
    }

    private func loadPhotoItems(_ items: [PhotosPickerItem]) {
        isLoadingPicks = true
        loadingCount = items.count
        Task {
            defer {
                isLoadingPicks = false
                photoItems = []
            }
            var failures = 0
            for item in items {
                guard pages.count < Self.maxImages else { break }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { failures += 1; continue }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    let url = Self.tempDirectory.appending(path: "\(UUID().uuidString).\(ext)")
                    try data.write(to: url, options: [.atomic])
                    if let picked = await Self.makePicked(url: url, name: item.itemIdentifier ?? "Photo") {
                        pages.append(picked)
                    } else {
                        try? FileManager.default.removeItem(at: url)
                        failures += 1
                    }
                } catch {
                    failures += 1
                }
                loadingCount -= 1
            }
            if failures > 0 {
                error = failures == 1
                    ? "1 photo couldn't be loaded. It may still be downloading from iCloud."
                    : "\(failures) photos couldn't be loaded. They may still be downloading from iCloud."
            }
        }
    }

    private func loadFileURLs(_ urls: [URL]) {
        isLoadingPicks = true
        loadingCount = urls.count
        Task {
            defer { isLoadingPicks = false }
            var failures = 0
            for source in urls {
                guard pages.count < Self.maxImages else { break }
                let didStart = source.startAccessingSecurityScopedResource()
                defer { if didStart { source.stopAccessingSecurityScopedResource() } }
                let url = Self.tempDirectory.appending(path: "\(UUID().uuidString).\(source.pathExtension)")
                do {
                    try FileManager.default.copyItem(at: source, to: url)
                } catch {
                    failures += 1
                    continue
                }
                if let picked = await Self.makePicked(url: url, name: source.deletingPathExtension().lastPathComponent) {
                    pages.append(picked)
                } else {
                    try? FileManager.default.removeItem(at: url)
                    failures += 1
                }
                loadingCount -= 1
            }
            if failures > 0 {
                error = failures == 1 ? "1 file isn't a readable image." : "\(failures) files aren't readable images."
            }
        }
    }

    nonisolated private static func makePicked(url: URL, name: String) async -> PickedImage? {
        await Task.detached(priority: .userInitiated) { () -> PickedImage? in
            guard ImagesToPDF.canDecode(url) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return PickedImage(url: url, thumbnail: UIImage(cgImage: cg), name: name)
        }.value
    }

    // MARK: - Convert

    private func convert() {
        guard !pages.isEmpty else { return }
        let snapshot = pages
        let opts = ImagesToPDF.Options(pageSize: pageSize, jpegQuality: quality.jpegQuality)
        let searchable = makeSearchable
        let finalTitle = DocumentStorage.sanitizedTitle(title, fallback: "Images")
        isWorking = true
        progressText = "Preparing…"

        Task {
            defer { isWorking = false }
            var pdfPages = snapshot.map { ImagesToPDF.Page(url: $0.url, quarterTurns: $0.quarterTurns) }
            var ocrText: [String] = []

            if searchable {
                for i in pdfPages.indices {
                    progressText = "Recognising text \(i + 1) of \(pdfPages.count)…"
                    let page = pdfPages[i]
                    if let image = await Task.detached(priority: .userInitiated, operation: { ImagesToPDF.renderedImage(for: page) }).value {
                        let boxes = await OCRPipeline.recognizeDetailed(image)
                        pdfPages[i].ocrBoxes = boxes
                        ocrText.append(boxes.map(\.string).joined(separator: "\n"))
                    }
                }
            }

            progressText = "Building PDF…"
            let output = Self.tempDirectory.appending(path: "\(UUID().uuidString).pdf")
            let pagesToWrite = pdfPages
            do {
                let count = try await Task.detached(priority: .userInitiated) {
                    try ImagesToPDF.write(pages: pagesToWrite, to: output, options: opts)
                }.value
                let doc = try DocumentStorage.adoptGeneratedPDF(at: output, title: finalTitle, into: modelContext)
                if searchable {
                    let joined = ocrText.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty { doc.ocrText = joined }
                }
                try? modelContext.save()
                cleanupTemp()
                pages = []
                success = ToolSuccessResult(
                    title: "PDF Created",
                    summary: "\(count) \(count == 1 ? "image" : "images") combined into \(finalTitle)"
                        + (searchable ? " with searchable text" : ""),
                    documents: [doc],
                    meteredFeature: nil
                )
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

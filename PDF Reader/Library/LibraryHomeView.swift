import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import VisionKit

/// Library — Document index with search, smart filters, folders, tags,
/// import + scan, grid/list view toggle.
struct LibraryHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]
    @Query(sort: \Folder.createdAt, order: .reverse) private var folders: [Folder]
    @Query(sort: \Tag.name) private var tags: [Tag]

    @AppStorage("settings.libraryViewMode")
    private var libraryViewModeRaw: String = LibraryViewMode.grid.rawValue

    @State private var showingImporter = false
    @State private var showingScanner = false
    @State private var showingFolderManager = false
    @State private var importError: String?
    @State private var isProcessingScan = false
    @State private var searchText = ""
    @State private var activeFilter: SmartFilter = .all
    @State private var selectedFolder: Folder?
    @State private var renamingDoc: Document?
    @State private var renameText = ""
    @State private var newTagDocument: Document?
    @State private var newTagName = ""
    @State private var showingPaywall = false

    private let entitlements = EntitlementStore.shared
    private let syncMonitor = ICloudSyncMonitor.shared

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: DesignSystem.Spacing.l)]

    private var viewMode: LibraryViewMode {
        LibraryViewMode(rawValue: libraryViewModeRaw) ?? .grid
    }

    private var syncStatusText: String {
        let count = syncMonitor.inProgressCount
        return count == 1 ? "Syncing 1 document…" : "Syncing \(count) documents…"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !entitlements.isPro {
                    UpgradeBanner {
                        showingPaywall = true
                    }
                    .padding(.horizontal, DesignSystem.Spacing.l)
                    .padding(.top, DesignSystem.Spacing.s)
                }
                filterChips
                contentArea
            }
            .navigationTitle(navTitle)
            .searchable(text: $searchText, prompt: "Search title or contents")
            .task {
                await DocumentStorage.bootstrapStorage()
                syncMonitor.start()
                await SearchableTextBackfill.runIfNeeded(in: modelContext)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    folderMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        libraryViewModeRaw = viewMode == .grid
                            ? LibraryViewMode.list.rawValue
                            : LibraryViewMode.grid.rawValue
                    } label: {
                        Label(
                            viewMode == .grid ? "List View" : "Grid View",
                            systemImage: viewMode == .grid ? "list.bullet" : "square.grid.2x2"
                        )
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    addMenu
                }
            }
            .navigationDestination(for: Document.self) { doc in
                ReaderView(document: doc)
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .fullScreenCover(isPresented: $showingScanner) {
                ScannerLauncher(onCompletion: handleScan)
            }
            .sheet(isPresented: $showingFolderManager) {
                FolderManagerView()
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: DesignSystem.Spacing.s) {
                    if syncMonitor.inProgressCount > 0 {
                        HStack(spacing: DesignSystem.Spacing.s) {
                            ProgressView()
                            Text(syncStatusText)
                                .font(.footnote)
                        }
                        .padding(.horizontal, DesignSystem.Spacing.l)
                        .padding(.vertical, DesignSystem.Spacing.m)
                        .glassEffect(.regular, in: .capsule)
                    }
                    if isProcessingScan {
                        HStack(spacing: DesignSystem.Spacing.s) {
                            ProgressView()
                            Text("Running OCR…")
                                .font(.footnote)
                        }
                        .padding(.horizontal, DesignSystem.Spacing.l)
                        .padding(.vertical, DesignSystem.Spacing.m)
                        .glassEffect(.regular, in: .capsule)
                    }
                }
                .padding(.bottom, DesignSystem.Spacing.xl)
            }
            .alert(
                "Couldn't add document",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { if !$0 { importError = nil } }
                )
            ) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .alert(
                "Rename",
                isPresented: Binding(
                    get: { renamingDoc != nil },
                    set: { if !$0 { renamingDoc = nil } }
                )
            ) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renamingDoc = nil }
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let doc = renamingDoc, !trimmed.isEmpty {
                        doc.title = trimmed
                    }
                    renamingDoc = nil
                }
            }
            .alert(
                "New Tag",
                isPresented: Binding(
                    get: { newTagDocument != nil },
                    set: { if !$0 { newTagDocument = nil; newTagName = "" } }
                )
            ) {
                TextField("Tag name", text: $newTagName)
                Button("Cancel", role: .cancel) {
                    newTagDocument = nil
                    newTagName = ""
                }
                Button("Create") {
                    let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let doc = newTagDocument, !trimmed.isEmpty {
                        let tag = Tag(name: trimmed)
                        modelContext.insert(tag)
                        doc.tags = (doc.tags ?? []) + [tag]
                    }
                    newTagDocument = nil
                    newTagName = ""
                }
            }
        }
    }

    // MARK: - Navigation title

    private var navTitle: String {
        selectedFolder?.name ?? "Library"
    }

    // MARK: - Filtering

    private var filteredDocuments: [Document] {
        var result = documents

        if let folder = selectedFolder {
            result = result.filter { $0.folder?.id == folder.id }
        }

        switch activeFilter {
        case .all:
            break
        case .recent:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
            result = result.filter { ($0.lastOpenedAt ?? $0.addedAt) >= cutoff }
        case .favorites:
            result = result.filter(\.isFavorite)
        case .signed:
            result = result.filter(\.isSigned)
        case .unread:
            result = result.filter(\.isUnread)
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result = result.filter { doc in
                doc.title.localizedCaseInsensitiveContains(trimmed)
                    || (doc.ocrText?.localizedCaseInsensitiveContains(trimmed) ?? false)
                    || (doc.tags ?? []).contains { $0.name.localizedCaseInsensitiveContains(trimmed) }
            }
        }

        return result
    }

    // MARK: - Toolbar

    private var folderMenu: some View {
        Menu {
            Button {
                selectedFolder = nil
            } label: {
                Label("All Documents", systemImage: "tray.full")
            }
            if !folders.isEmpty {
                Divider()
                ForEach(folders) { folder in
                    Button {
                        selectedFolder = folder
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(folder.name)
                            Spacer()
                            Text("\((folder.documents ?? []).count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            Button {
                showingFolderManager = true
            } label: {
                Label("Manage Folders…", systemImage: "folder.badge.gearshape")
            }
        } label: {
            if let selectedFolder {
                Label(selectedFolder.name, systemImage: "folder")
            } else {
                Label("All Documents", systemImage: "tray.full")
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                showingImporter = true
            } label: {
                Label("Import PDF", systemImage: "square.and.arrow.down")
            }
            if VNDocumentCameraViewController.isSupported {
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan Document", systemImage: "doc.viewfinder")
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    // MARK: - Filter chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.s) {
                ForEach(SmartFilter.allCases) { filter in
                    Button {
                        activeFilter = filter
                    } label: {
                        GlassChip(
                            title: filter.title,
                            systemImage: filter.systemImage,
                            tint: activeFilter == filter ? .accentColor : nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.l)
            .padding(.vertical, DesignSystem.Spacing.s)
        }
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if documents.isEmpty {
            emptyState
        } else if filteredDocuments.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            switch viewMode {
            case .grid: documentGrid
            case .list: documentList
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No PDFs yet", systemImage: "books.vertical")
        } description: {
            Text("Import a PDF or scan a document to get started.")
        } actions: {
            VStack(spacing: DesignSystem.Spacing.s) {
                Button("Import PDF") { showingImporter = true }
                    .buttonStyle(.glassProminent)
                if VNDocumentCameraViewController.isSupported {
                    Button("Scan Document") { showingScanner = true }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var documentGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.l) {
                ForEach(filteredDocuments) { doc in
                    NavigationLink(value: doc) {
                        DocumentCard(document: doc)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        documentContextMenu(for: doc)
                    }
                }
            }
            .padding(DesignSystem.Spacing.l)
        }
    }

    private var documentList: some View {
        List {
            ForEach(filteredDocuments) { doc in
                NavigationLink(value: doc) {
                    DocumentListRow(document: doc)
                }
                .contextMenu {
                    documentContextMenu(for: doc)
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func documentContextMenu(for doc: Document) -> some View {
        if horizontalSizeClass == .regular {
            Button {
                openWindow(value: doc.id)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            Divider()
        }
        Button {
            doc.isFavorite.toggle()
        } label: {
            Label(
                doc.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: doc.isFavorite ? "star.slash" : "star"
            )
        }
        Menu {
            Button {
                doc.folder = nil
            } label: {
                HStack {
                    Text("(No folder)")
                    if doc.folder == nil { Image(systemName: "checkmark") }
                }
            }
            if !folders.isEmpty { Divider() }
            ForEach(folders) { folder in
                Button {
                    doc.folder = folder
                } label: {
                    HStack {
                        Text(folder.name)
                        if doc.folder?.id == folder.id { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
        Menu {
            if !tags.isEmpty {
                ForEach(tags) { tag in
                    Button {
                        toggleTag(tag, on: doc)
                    } label: {
                        HStack {
                            Text(tag.name)
                            if (doc.tags ?? []).contains(where: { $0.id == tag.id }) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
            }
            Button {
                newTagDocument = doc
                newTagName = ""
            } label: {
                Label("New Tag…", systemImage: "tag.badge.plus")
            }
        } label: {
            Label("Tags", systemImage: "tag")
        }
        Button {
            renameText = doc.title
            renamingDoc = doc
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        ShareLink(item: doc.fileURL) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            DocumentStorage.delete(doc, in: modelContext)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func toggleTag(_ tag: Tag, on doc: Document) {
        var tags = doc.tags ?? []
        if let index = tags.firstIndex(where: { $0.id == tag.id }) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        doc.tags = tags
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                do {
                    let imported = try DocumentStorage.importPDF(from: url, into: modelContext)
                    if let folder = selectedFolder {
                        imported.folder = folder
                    }
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func handleScan(_ result: Result<[UIImage], any Error>) {
        switch result {
        case .success(let images) where !images.isEmpty:
            let targetFolder = selectedFolder
            Task {
                isProcessingScan = true
                defer { isProcessingScan = false }
                do {
                    let scanned = try await ScanToPDF.createDocument(from: images, in: modelContext)
                    if let folder = targetFolder {
                        scanned.folder = folder
                    }
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .success:
            break
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

// MARK: - Library view mode

enum LibraryViewMode: String { case grid, list }

// MARK: - SmartFilter

enum SmartFilter: String, CaseIterable, Identifiable {
    case all, recent, favorites, signed, unread
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .signed: "Signed"
        case .unread: "Unread"
        }
    }
    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .recent: "clock"
        case .favorites: "star.fill"
        case .signed: "signature"
        case .unread: "envelope.badge"
        }
    }
}

// MARK: - DocumentCard

private struct DocumentCard: View {
    let document: Document

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
                DocumentThumbnailView(
                    documentID: document.id,
                    documentURL: document.fileURL,
                    placeholderIconSize: 32
                )
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if document.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .padding(DesignSystem.Spacing.xs)
                    }
                }
                Text(document.title)
                    .font(.headline)
                    .lineLimit(2)
                if let tags = document.tags, !tags.isEmpty {
                    TagRow(tags: tags, limit: 3)
                }
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text("\(document.pageCount) pages")
                    if document.ocrText != nil {
                        Text("·")
                        Image(systemName: "text.viewfinder")
                    }
                    if document.isSigned {
                        Text("·")
                        Image(systemName: "signature")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - DocumentListRow

private struct DocumentListRow: View {
    let document: Document

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            DocumentThumbnailView(
                documentID: document.id,
                documentURL: document.fileURL,
                placeholderIconSize: 16
            )
            .frame(width: 44, height: 56)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                    if document.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
                }
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text("\(document.pageCount) pages")
                    if document.ocrText != nil {
                        Text("·")
                        Image(systemName: "text.viewfinder")
                    }
                    if document.isSigned {
                        Text("·")
                        Image(systemName: "signature")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let tags = document.tags, !tags.isEmpty {
                    TagRow(tags: tags, limit: 4)
                }
            }
            Spacer()
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }
}

private struct TagRow: View {
    let tags: [Tag]
    let limit: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(limit)) { tag in
                Text(tag.name)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.tint.opacity(0.18)))
            }
            if tags.count > limit {
                Text("+\(tags.count - limit)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    LibraryHomeView()
        .modelContainer(for: [Document.self, Folder.self, Tag.self], inMemory: true)
}

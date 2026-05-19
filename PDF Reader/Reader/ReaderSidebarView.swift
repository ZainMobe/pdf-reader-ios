import SwiftUI
import SwiftData
import PDFKit

/// Reader-side navigation surface — page thumbnails, the PDF outline,
/// user-created bookmarks, and a flat list of all annotations.
struct ReaderSidebarView: View {
    @Bindable var document: Document
    let currentPageIndex: Int
    let onNavigatePage: (Int) -> Void
    let onNavigateDestination: (PDFDestination) -> Void
    let onNavigateAnnotation: (PDFAnnotation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var section: SidebarSection = .pages

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(SidebarSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(DesignSystem.Spacing.m)

                Divider()

                switch section {
                case .pages:
                    ThumbnailList(documentURL: document.fileURL) { pageIndex in
                        onNavigatePage(pageIndex)
                        dismiss()
                    }
                case .outline:
                    OutlineList(documentURL: document.fileURL) { destination in
                        onNavigateDestination(destination)
                        dismiss()
                    }
                case .bookmarks:
                    BookmarkList(
                        document: document,
                        currentPageIndex: currentPageIndex
                    ) { pageIndex in
                        onNavigatePage(pageIndex)
                        dismiss()
                    }
                case .annotations:
                    AnnotationsList(documentURL: document.fileURL) { annotation in
                        onNavigateAnnotation(annotation)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case pages, outline, bookmarks, annotations
    var id: Self { self }
    var title: String {
        switch self {
        case .pages: "Pages"
        case .outline: "Outline"
        case .bookmarks: "Bookmarks"
        case .annotations: "Notes"
        }
    }
}

// MARK: - Thumbnails

private struct ThumbnailList: View {
    let documentURL: URL
    let onTap: (Int) -> Void
    @State private var pages: [PDFPage] = []

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: DesignSystem.Spacing.m)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.m) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    Button {
                        onTap(index)
                    } label: {
                        VStack(spacing: DesignSystem.Spacing.xs) {
                            PageThumbnail(page: page, size: CGSize(width: 120, height: 160))
                                .frame(width: 120, height: 160)
                                .background(RoundedRectangle(cornerRadius: DesignSystem.Radius.small).fill(.tertiary))
                            Text("Page \(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignSystem.Spacing.l)
        }
        .task {
            if let pdf = PDFDocument(url: documentURL) {
                pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
            }
        }
    }
}

// MARK: - Outline

private struct OutlineList: View {
    let documentURL: URL
    let onTap: (PDFDestination) -> Void
    @State private var outline: PDFOutline?
    @State private var loaded = false

    var body: some View {
        Group {
            if let outline, outline.numberOfChildren > 0 {
                List {
                    OutlineRow(outline: outline, onTap: onTap)
                }
            } else if loaded {
                ContentUnavailableView(
                    "No Outline",
                    systemImage: "list.bullet.indent",
                    description: Text("This PDF doesn't include a table of contents.")
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            outline = PDFDocument(url: documentURL)?.outlineRoot
            loaded = true
        }
    }
}

private struct OutlineRow: View {
    let outline: PDFOutline
    let onTap: (PDFDestination) -> Void

    private var childIndices: [Int] {
        (0..<outline.numberOfChildren).map { $0 }
    }

    var body: some View {
        ForEach(childIndices, id: \.self) { index in
            if let child = outline.child(at: index) {
                row(for: child)
            }
        }
    }

    @ViewBuilder
    private func row(for entry: PDFOutline) -> some View {
        if entry.numberOfChildren > 0 {
            DisclosureGroup {
                OutlineRow(outline: entry, onTap: onTap)
            } label: {
                rowLabel(entry)
            }
        } else {
            rowLabel(entry)
        }
    }

    private func rowLabel(_ entry: PDFOutline) -> some View {
        Button {
            if let destination = entry.destination {
                onTap(destination)
            }
        } label: {
            Text(entry.label ?? "Untitled")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bookmarks

private struct BookmarkList: View {
    let document: Document
    let currentPageIndex: Int
    let onTap: (Int) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var allBookmarks: [Bookmark]

    init(document: Document, currentPageIndex: Int, onTap: @escaping (Int) -> Void) {
        self.document = document
        self.currentPageIndex = currentPageIndex
        self.onTap = onTap
        let documentID = document.id
        _allBookmarks = Query(
            filter: #Predicate<Bookmark> { $0.documentID == documentID },
            sort: \Bookmark.pageIndex
        )
    }

    var body: some View {
        List {
            Section {
                Button {
                    addBookmarkForCurrentPage()
                } label: {
                    Label("Bookmark Page \(currentPageIndex + 1)", systemImage: "bookmark.fill")
                }
            }
            if allBookmarks.isEmpty {
                Section {
                    Text("No bookmarks yet. Tap the button above to add one for the page you're on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Saved") {
                    ForEach(allBookmarks) { bookmark in
                        Button {
                            onTap(bookmark.pageIndex)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(bookmark.label)
                                        .font(.headline)
                                    Text("Page \(bookmark.pageIndex + 1)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            modelContext.delete(allBookmarks[index])
                        }
                    }
                }
            }
        }
    }

    private func addBookmarkForCurrentPage() {
        let bookmark = Bookmark(
            documentID: document.id,
            pageIndex: currentPageIndex,
            label: "Page \(currentPageIndex + 1)"
        )
        modelContext.insert(bookmark)
    }
}

// MARK: - Annotations

private struct AnnotationsList: View {
    let documentURL: URL
    let onTap: (PDFAnnotation) -> Void
    @State private var entries: [Entry] = []
    @State private var loaded = false

    struct Entry: Identifiable {
        let id = UUID()
        let annotation: PDFAnnotation
        let pageIndex: Int
    }

    var body: some View {
        Group {
            if !entries.isEmpty {
                List(entries) { entry in
                    Button {
                        onTap(entry.annotation)
                    } label: {
                        AnnotationRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            } else if loaded {
                ContentUnavailableView(
                    "No Annotations",
                    systemImage: "highlighter",
                    description: Text("Highlights, sticky notes, and ink show up here once you add them.")
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { load() }
    }

    private func load() {
        guard let pdf = PDFDocument(url: documentURL) else {
            loaded = true
            return
        }
        var collected: [Entry] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            for annotation in page.annotations where shouldList(annotation) {
                collected.append(Entry(annotation: annotation, pageIndex: index))
            }
        }
        entries = collected
        loaded = true
    }

    private func shouldList(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type else { return false }
        // Hide widgets, links, and other interactive types.
        let listable: Set<String> = ["Highlight", "Underline", "StrikeOut", "Ink", "FreeText", "Text", "Square", "Stamp"]
        return listable.contains(type)
    }
}

private struct AnnotationRow: View {
    let entry: AnnotationsList.Entry

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.m) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let preview = previewText {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("Page \(entry.pageIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var systemImage: String {
        switch entry.annotation.type ?? "" {
        case "Highlight": "highlighter"
        case "Underline": "underline"
        case "StrikeOut": "strikethrough"
        case "Ink": "scribble.variable"
        case "FreeText": "character.textbox"
        case "Text": "note.text"
        case "Square": "rectangle.fill"
        case "Stamp": "signature"
        default: "doc.text"
        }
    }

    private var title: String {
        switch entry.annotation.type ?? "" {
        case "Highlight": "Highlight"
        case "Underline": "Underline"
        case "StrikeOut": "Strikethrough"
        case "Ink": "Ink"
        case "FreeText": "Text"
        case "Text": "Note"
        case "Square": "Redaction"
        case "Stamp": "Stamp"
        default: "Annotation"
        }
    }

    private var previewText: String? {
        let raw = entry.annotation.contents?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }
}

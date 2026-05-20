import SwiftUI
import PDFKit

/// Full-text search across the open PDF. Each match shows the page number and
/// a ~80-character snippet around the matched string; tapping a row dismisses
/// the sheet and navigates the reader to that selection.
struct SearchSheet: View {
    let document: Document
    let onSelect: (PDFSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Match] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var pdf: PDFDocument?

    nonisolated private static let maxResults = 200

    struct Match: Identifiable {
        let id = UUID()
        let pageIndex: Int
        let snippet: AttributedString
        let selection: PDFSelection
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                resultsList
            }
            .navigationTitle("Find in PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if pdf == nil {
                    pdf = PDFDocument(url: document.fileURL)
                }
            }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in this document", text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit(runSearch)
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    hasSearched = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DesignSystem.Spacing.m)
    }

    @ViewBuilder
    private var resultsList: some View {
        if isSearching {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasSearched && results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if !results.isEmpty {
            List(results) { match in
                Button {
                    onSelect(match.selection)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Page \(match.pageIndex + 1)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                        Text(match.snippet)
                            .font(.subheadline)
                            .lineLimit(3)
                    }
                    .padding(.vertical, DesignSystem.Spacing.xs)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        } else {
            ContentUnavailableView(
                "Find in PDF",
                systemImage: "magnifyingglass",
                description: Text("Type a word or phrase and tap return to search.")
            )
        }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pdf else {
            results = []
            hasSearched = !trimmed.isEmpty
            return
        }
        isSearching = true
        hasSearched = true

        Task.detached {
            let selections = pdf.findString(trimmed, withOptions: .caseInsensitive)
            let limited = selections.prefix(Self.maxResults)
            let matches = limited.compactMap { selection -> Match? in
                guard let page = selection.pages.first else { return nil }
                let pageIndex = pdf.index(for: page)
                guard pageIndex >= 0 else { return nil }
                let snippet = Self.makeSnippet(for: selection, in: page, query: trimmed)
                return Match(pageIndex: pageIndex, snippet: snippet, selection: selection)
            }
            await MainActor.run {
                self.results = Array(matches)
                self.isSearching = false
            }
        }
    }

    nonisolated private static func makeSnippet(for selection: PDFSelection, in page: PDFPage, query: String) -> AttributedString {
        let fallback = AttributedString(selection.string ?? query)
        guard
            let pageText = page.string,
            let matched = selection.string,
            let range = pageText.range(of: matched, options: .caseInsensitive)
        else {
            return fallback
        }

        let leadStart = pageText.index(range.lowerBound, offsetBy: -40, limitedBy: pageText.startIndex)
            ?? pageText.startIndex
        let tailEnd = pageText.index(range.upperBound, offsetBy: 40, limitedBy: pageText.endIndex)
            ?? pageText.endIndex

        let leadEllipsis = leadStart == pageText.startIndex ? "" : "…"
        let tailEllipsis = tailEnd == pageText.endIndex ? "" : "…"

        let prefix = String(pageText[leadStart..<range.lowerBound]).replacingOccurrences(of: "\n", with: " ")
        let match = String(pageText[range])
        let suffix = String(pageText[range.upperBound..<tailEnd]).replacingOccurrences(of: "\n", with: " ")

        var attributed = AttributedString(leadEllipsis + prefix)
        var highlighted = AttributedString(match)
        highlighted.backgroundColor = .yellow.opacity(0.35)
        highlighted.font = .body.bold()
        attributed += highlighted
        attributed += AttributedString(suffix + tailEllipsis)
        return attributed
    }
}

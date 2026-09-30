import SwiftData
import SwiftUI

/// Full-screen "Ask your Library" experience.
struct LibrarySearchView: View {
    var initialQuery: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Document.addedAt, order: .reverse) private var documents: [Document]

    @State private var ask = LibraryAsk()
    @State private var query = ""
    @State private var openingSource: Int?
    @FocusState private var fieldFocused: Bool

    private let router = IncomingFileRouter.shared

    private let suggestions = [
        "Which document mentions a deadline this month?",
        "Find the invoice with the largest total",
        "What does my lease say about deposits?",
        "Summarise what all my contracts have in common",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    searchField
                    switch ask.status {
                    case .idle:
                        idleContent
                    case .indexing:
                        HStack(spacing: DesignSystem.Spacing.s) {
                            ProgressView()
                            Text("Indexing your library…").foregroundStyle(.secondary)
                        }
                    case .searching:
                        HStack(spacing: DesignSystem.Spacing.s) {
                            ProgressView()
                            Text("Searching \(documentsWithTextCount) documents…").foregroundStyle(.secondary)
                        }
                    case .answering, .done, .failed:
                        resultsContent
                    }
                }
                .padding(DesignSystem.Spacing.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Ask your Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: documents.count) {
                await ask.refreshIndex(from: documents)
            }
            .onAppear {
                if !initialQuery.isEmpty, query.isEmpty {
                    query = initialQuery
                    Task {
                        await ask.refreshIndex(from: documents)
                        submit()
                    }
                } else {
                    fieldFocused = true
                }
            }
        }
    }

    private var documentsWithTextCount: Int {
        documents.filter { !($0.ocrText ?? "").isEmpty }.count
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: DesignSystem.Spacing.s) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.tint)
            TextField("Ask anything across all your PDFs", text: $query, axis: .vertical)
                .lineLimit(1...3)
                .focused($fieldFocused)
                .submitLabel(.search)
                .onSubmit { submit() }
            if !query.isEmpty {
                Button {
                    query = ""
                    ask.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if ask.isAnswerStreaming {
                Button { ask.cancel() } label: { Image(systemName: "stop.circle.fill") }
                    .buttonStyle(.plain)
            } else {
                Button { submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.m)
        .padding(.vertical, DesignSystem.Spacing.s)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
    }

    @ViewBuilder
    private var idleContent: some View {
        if documentsWithTextCount == 0 {
            ContentUnavailableView(
                "Nothing to search yet",
                systemImage: "books.vertical",
                description: Text("Add PDFs to your Library. Scanned documents become searchable once OCR has run.")
            )
        } else {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.m) {
                Text("Searches \(documentsWithTextCount) \(documentsWithTextCount == 1 ? "document" : "documents") on this device. \(ask.canAnswer ? "Answers come from Apple Intelligence and cite the exact passages." : "Apple Intelligence is off, so you'll get the best matching passages without a written answer.")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Try asking")
                    .font(.subheadline.weight(.semibold))
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        query = suggestion
                        submit()
                    } label: {
                        HStack {
                            Text(suggestion)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left").foregroundStyle(.secondary).font(.caption)
                        }
                        .padding(DesignSystem.Spacing.m)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: DesignSystem.Radius.medium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        if ask.sources.isEmpty {
            ContentUnavailableView.search(text: ask.lastQuery)
        } else {
            if ask.canAnswer {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.s) {
                    HStack {
                        Label("Answer", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                        if ask.isAnswerStreaming { ProgressView().controlSize(.mini) }
                    }
                    if case .failed(let message) = ask.status, ask.answer.isEmpty {
                        Text(message).foregroundStyle(.secondary)
                    } else {
                        CitedText(text: ask.answer.isEmpty && ask.isAnswerStreaming ? "…" : ask.answer) { number in
                            open(sourceNumber: number)
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(DesignSystem.Spacing.l)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: DesignSystem.Radius.medium, style: .continuous))
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.m) {
                Text(ask.canAnswer ? "Sources" : "Best matches")
                    .font(.subheadline.weight(.semibold))
                ForEach(ask.sources) { source in
                    Button {
                        open(sourceNumber: source.id)
                    } label: {
                        sourceCard(source)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sourceCard(_ source: LibraryAsk.Source) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.m) {
            Text("\(source.id)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(source.documentTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    if openingSource == source.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Text(highlighted(source.passage, terms: LibrarySearchIndex.tokenize(ask.lastQuery)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .padding(DesignSystem.Spacing.m)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: DesignSystem.Radius.medium, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Bolds query terms inside a snippet.
    private func highlighted(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString(String(text.prefix(360)))
        let lowered = String(text.prefix(360)).lowercased()
        for term in Set(terms) where term.count > 2 {
            var searchRange = lowered.startIndex..<lowered.endIndex
            while let range = lowered.range(of: term, range: searchRange) {
                if let attrRange = Range(NSRange(range, in: lowered), in: result) {
                    result[attrRange].font = .footnote.weight(.semibold)
                    result[attrRange].foregroundColor = .primary
                }
                searchRange = range.upperBound..<lowered.endIndex
            }
        }
        return result
    }

    // MARK: - Actions

    private func submit() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        fieldFocused = false
        Haptics.impact(.light)
        ask.ask(q)
    }

    private func open(sourceNumber: Int) {
        guard let source = ask.sources.first(where: { $0.id == sourceNumber }),
              let doc = documents.first(where: { $0.id == source.documentID }) else { return }
        openingSource = sourceNumber
        Task {
            let page = await LibraryAsk.pageIndex(for: source.passage, in: doc.fileURL)
            openingSource = nil
            router.pageToOpen = page
            router.documentToOpen = doc.id
            router.libraryRequestToken &+= 1
            dismiss()
        }
    }
}

/// Renders text containing [n] citations as tappable superscript-style chips.
private struct CitedText: View {
    let text: String
    let onTap: (Int) -> Void

    var body: some View {
        // Build an AttributedString with links for each [n]; SwiftUI's Text
        // opens links through `openURL`, which we intercept.
        Text(attributed)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "cite", let n = Int(url.host() ?? "") {
                    onTap(n)
                    return .handled
                }
                return .systemAction
            })
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let pattern = try? NSRegularExpression(pattern: #"\[(\d{1,2})\]"#)
        let ns = text as NSString
        var last = 0
        for match in pattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if match.range.location > last {
                result += AttributedString(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            }
            let number = ns.substring(with: match.range(at: 1))
            var chip = AttributedString(" \(number) ")
            chip.link = URL(string: "cite://\(number)")
            chip.font = .caption.weight(.bold)
            chip.foregroundColor = .white
            chip.backgroundColor = .accentColor
            result += chip
            last = match.range.location + match.range.length
        }
        if last < ns.length {
            result += AttributedString(ns.substring(from: last))
        }
        return result
    }
}

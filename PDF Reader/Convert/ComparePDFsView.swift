import SwiftData
import SwiftUI

/// Tool sheet: pick two documents and see what changed, as text
/// differences, side by side pages, or an overlay.
struct ComparePDFsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var docA: Document?
    @State private var docB: Document?
    @State private var isWorking = false
    @State private var error: String?
    @State private var result: PDFCompare.Result?

    var body: some View {
        NavigationStack {
            Group {
                if let result, let docA, let docB {
                    CompareResultsView(result: result, docA: docA, docB: docB)
                } else {
                    Form {
                        SourceDocumentSection(selected: $docA, title: "Original")
                        SourceDocumentSection(selected: $docB, title: "Revised")
                        Section {
                            Text("Pages are compared in order. Text changes are shown word by word; the visual views help with layout, images and scans.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(result == nil ? "Compare PDFs" : "Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if result == nil {
                        Button("Cancel") { dismiss() }.disabled(isWorking)
                    } else {
                        Button("Back") { result = nil }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if result == nil {
                        Button("Compare") { compare() }
                            .buttonStyle(.glassProminent)
                            .disabled(docA == nil || docB == nil || docA?.id == docB?.id || isWorking)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .overlay {
                if isWorking {
                    VStack(spacing: DesignSystem.Spacing.s) {
                        ProgressView()
                        Text("Comparing…").font(.subheadline)
                    }
                    .padding(DesignSystem.Spacing.xl)
                    .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
                }
            }
            .alert("Couldn't compare", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func compare() {
        guard let a = docA, let b = docB else { return }
        let urlA = a.fileURL, urlB = b.fileURL
        isWorking = true
        Task {
            defer { isWorking = false }
            await DocumentStorage.ensureDownloaded(at: urlA)
            await DocumentStorage.ensureDownloaded(at: urlB)
            do {
                result = try await Task.detached(priority: .userInitiated) {
                    try PDFCompare.compare(urlA, urlB)
                }.value
                Haptics.success()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct CompareResultsView: View {
    let result: PDFCompare.Result
    let docA: Document
    let docB: Document

    enum Mode: String, CaseIterable, Identifiable {
        case text, sideBySide, overlay
        var id: Self { self }
        var title: String {
            switch self {
            case .text: "Text"
            case .sideBySide: "Side by Side"
            case .overlay: "Overlay"
            }
        }
    }

    @State private var mode: Mode = .text
    @State private var pageIndex = 0
    @State private var onlyChanged = true
    @State private var imageA: UIImage?
    @State private var imageB: UIImage?
    @State private var overlayOpacity: Double = 0.5

    private var pageCount: Int { result.pages.count }
    private var page: PDFCompare.PageResult? { result.pages.indices.contains(pageIndex) ? result.pages[pageIndex] : nil }

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DesignSystem.Spacing.l)
            .padding(.vertical, DesignSystem.Spacing.s)

            Group {
                switch mode {
                case .text: textView
                case .sideBySide: sideBySideView
                case .overlay: overlayView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            pageBar
        }
        .task(id: pageIndex) { await loadImages() }
        .onAppear {
            if let first = result.changedPages.first { pageIndex = first }
        }
    }

    // MARK: - Bars

    private var summaryBar: some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            if result.identical {
                Label("No text differences", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("\(result.changedPages.count) of \(pageCount) pages changed", systemImage: "doc.badge.ellipsis")
                Spacer()
                Text("+\(result.totalAdded)").foregroundStyle(.green).monospacedDigit()
                Text("−\(result.totalRemoved)").foregroundStyle(.red).monospacedDigit()
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, DesignSystem.Spacing.l)
        .padding(.top, DesignSystem.Spacing.s)
    }

    private var pageBar: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(previousIndex == nil)
            Spacer()
            VStack(spacing: 2) {
                Text("Page \(pageIndex + 1) of \(pageCount)")
                    .font(.subheadline.weight(.semibold))
                if let page {
                    Text(pageStatus(page))
                        .font(.caption)
                        .foregroundStyle(page.hasChanges ? .orange : .secondary)
                }
            }
            Spacer()
            Toggle(isOn: $onlyChanged) { Text("Changed only") }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(result.identical)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(nextIndex == nil)
        }
        .padding(DesignSystem.Spacing.m)
        .background(.bar)
    }

    private func pageStatus(_ page: PDFCompare.PageResult) -> String {
        if !page.existsInA { return "Only in revised" }
        if !page.existsInB { return "Only in original" }
        if !page.hasChanges { return "Unchanged" }
        return "+\(page.wordsAdded) −\(page.wordsRemoved) words"
    }

    private var previousIndex: Int? {
        let candidates = onlyChanged && !result.identical ? result.changedPages : Array(0..<pageCount)
        return candidates.last { $0 < pageIndex }
    }

    private var nextIndex: Int? {
        let candidates = onlyChanged && !result.identical ? result.changedPages : Array(0..<pageCount)
        return candidates.first { $0 > pageIndex }
    }

    private func step(_ direction: Int) {
        if direction < 0, let p = previousIndex { pageIndex = p }
        if direction > 0, let n = nextIndex { pageIndex = n }
        Haptics.selection()
    }

    // MARK: - Modes

    private var textView: some View {
        ScrollView {
            if let page {
                if page.segments.isEmpty {
                    ContentUnavailableView("No text on this page", systemImage: "doc", description: Text("Use Side by Side or Overlay to compare scans and images."))
                } else {
                    Text(attributed(page.segments))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignSystem.Spacing.l)
                }
            }
        }
    }

    private func attributed(_ segments: [PDFCompare.Segment]) -> AttributedString {
        var out = AttributedString()
        for segment in segments {
            switch segment {
            case .same(let s):
                out += AttributedString(s + " ")
            case .added(let s):
                var a = AttributedString(s + " ")
                a.backgroundColor = Color.green.opacity(0.25)
                a.foregroundColor = .primary
                out += a
            case .removed(let s):
                var r = AttributedString(s + " ")
                r.backgroundColor = Color.red.opacity(0.2)
                r.strikethroughStyle = .single
                r.foregroundColor = .secondary
                out += r
            }
        }
        return out
    }

    private var sideBySideView: some View {
        GeometryReader { proxy in
            let vertical = proxy.size.width < 600
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                pagePanel(title: docA.title, image: imageA, missing: page?.existsInA == false)
                pagePanel(title: docB.title, image: imageB, missing: page?.existsInB == false)
            }
            .padding(DesignSystem.Spacing.m)
        }
    }

    private func pagePanel(title: String, image: UIImage?, missing: Bool) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                if missing {
                    Text("No page").foregroundStyle(.secondary)
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit().padding(4)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var overlayView: some View {
        VStack(spacing: DesignSystem.Spacing.s) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.small, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                if let imageA {
                    Image(uiImage: imageA).resizable().scaledToFit().padding(4)
                }
                if let imageB {
                    Image(uiImage: imageB).resizable().scaledToFit().padding(4)
                        .opacity(overlayOpacity)
                }
                if imageA == nil && imageB == nil { ProgressView() }
            }
            HStack {
                Text(docA.title).font(.caption).lineLimit(1)
                Slider(value: $overlayOpacity, in: 0...1)
                Text(docB.title).font(.caption).lineLimit(1)
            }
            .padding(.horizontal, DesignSystem.Spacing.m)
            Text("Slide to fade between versions. Differences in layout or images stand out as the page changes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(DesignSystem.Spacing.m)
    }

    private func loadImages() async {
        imageA = nil
        imageB = nil
        let urlA = docA.fileURL, urlB = docB.fileURL, index = pageIndex
        let pair = await Task.detached(priority: .userInitiated) {
            (PDFCompare.image(of: urlA, page: index), PDFCompare.image(of: urlB, page: index))
        }.value
        guard index == pageIndex else { return }
        imageA = pair.0
        imageB = pair.1
    }
}

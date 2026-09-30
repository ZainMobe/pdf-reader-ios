import SwiftUI
import WidgetKit

/// Recently opened documents, deep-linking straight into the Reader.
struct RecentDocumentsWidget: Widget {
    let kind = "RecentDocuments"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentsProvider()) { entry in
            RecentsView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Recent Documents")
        .description("Jump back into what you were reading.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct RecentsEntry: TimelineEntry {
    let date: Date
    let recents: [WidgetSnapshot.Recent]
    let documentCount: Int
    let isPlaceholder: Bool
}

struct RecentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentsEntry {
        RecentsEntry(date: .now, recents: Self.sample, documentCount: 3, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentsEntry) -> Void) {
        completion(load(placeholderIfEmpty: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentsEntry>) -> Void) {
        // The app reloads timelines whenever the Library changes; a daily
        // refresh keeps relative dates honest in between.
        let entry = load(placeholderIfEmpty: false)
        let next = Calendar.current.date(byAdding: .hour, value: 12, to: .now) ?? .now.addingTimeInterval(43_200)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load(placeholderIfEmpty: Bool) -> RecentsEntry {
        if let payload = WidgetSnapshot.read(), !payload.recents.isEmpty {
            return RecentsEntry(date: .now, recents: payload.recents, documentCount: payload.documentCount, isPlaceholder: false)
        }
        return RecentsEntry(date: .now, recents: placeholderIfEmpty ? Self.sample : [], documentCount: 0, isPlaceholder: placeholderIfEmpty)
    }

    static let sample: [WidgetSnapshot.Recent] = [
        .init(id: UUID(), title: "Lease Agreement", pageCount: 12, lastOpened: .now, thumbnail: nil),
        .init(id: UUID(), title: "Q3 Invoice", pageCount: 2, lastOpened: .now.addingTimeInterval(-3600), thumbnail: nil),
        .init(id: UUID(), title: "Research Notes", pageCount: 34, lastOpened: .now.addingTimeInterval(-86_400), thumbnail: nil),
    ]
}

struct RecentsView: View {
    let entry: RecentsEntry
    @Environment(\.widgetFamily) private var family

    private var visible: [WidgetSnapshot.Recent] {
        Array(entry.recents.prefix(family == .systemLarge ? 6 : 3))
    }

    var body: some View {
        if entry.recents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.title)
                    .foregroundStyle(.tint)
                Text("No documents yet")
                    .font(.headline)
                Text("Scan or import a PDF to see it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(URL(string: "pdfeditor://scan"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link(destination: URL(string: "pdfeditor://scan")!) {
                        Image(systemName: "doc.viewfinder")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                ForEach(visible) { recent in
                    Link(destination: recent.deepLink) {
                        row(recent)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ recent: WidgetSnapshot.Recent) -> some View {
        HStack(spacing: 10) {
            Group {
                if let url = WidgetSnapshot.thumbnailURL(for: recent),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "doc.text")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 34)
            .background(.fill.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(recent.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Text(subtitle(recent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }

    private func subtitle(_ recent: WidgetSnapshot.Recent) -> String {
        let pages = "\(recent.pageCount) \(recent.pageCount == 1 ? "page" : "pages")"
        if let opened = recent.lastOpened {
            return pages + " · " + opened.formatted(.relative(presentation: .named))
        }
        return pages
    }
}

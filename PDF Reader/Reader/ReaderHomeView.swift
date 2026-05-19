import SwiftUI
import SwiftData

/// Reader — Viewer UI, page modes, outline, thumbnails, bookmarks, multi-tab/multi-window.
///
/// The home view shows "Continue Reading" — documents the user has opened
/// before, sorted by most-recent. Tapping a row opens `ReaderView`.
struct ReaderHomeView: View {
    @Query(
        filter: #Predicate<Document> { $0.lastOpenedAt != nil },
        sort: \Document.lastOpenedAt,
        order: .reverse
    )
    private var recents: [Document]

    var body: some View {
        NavigationStack {
            Group {
                if recents.isEmpty {
                    ContentUnavailableView(
                        "Nothing to continue",
                        systemImage: "doc.text",
                        description: Text("Open a document from your Library to start reading.")
                    )
                } else {
                    List(recents) { doc in
                        NavigationLink(value: doc) {
                            RecentRow(document: doc)
                        }
                    }
                }
            }
            .navigationTitle("Continue Reading")
            .navigationDestination(for: Document.self) { doc in
                ReaderView(document: doc)
            }
        }
    }
}

private struct RecentRow: View {
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
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                if let last = document.lastOpenedAt {
                    Text("Opened \(Self.formatLastOpened(last))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Renders a stable, non-ticking timestamp string. `Text(_:style:.relative)`
    /// auto-updates every second, which made the Read tab look glitchy as
    /// rows kept flickering. We snapshot a calendar-aware string at render
    /// time — "Today, 2:34 PM", "Yesterday, 3:12 PM", "Mon 9:08 AM",
    /// or "May 12, 2026" once the date is older than a week.
    private static func formatLastOpened(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "today at \(date.formatted(date: .omitted, time: .shortened))"
        }
        if calendar.isDateInYesterday(date) {
            return "yesterday at \(date.formatted(date: .omitted, time: .shortened))"
        }
        let daysAgo = calendar.dateComponents([.day], from: date, to: .now).day ?? 0
        if daysAgo < 7 {
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

#Preview {
    ReaderHomeView()
        .modelContainer(for: [Document.self, Folder.self, Tag.self], inMemory: true)
}

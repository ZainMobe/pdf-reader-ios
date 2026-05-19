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
            RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                .fill(.tertiary)
                .frame(width: 44, height: 56)
                .overlay {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                }
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                if let last = document.lastOpenedAt {
                    Text("Opened \(last, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    ReaderHomeView()
        .modelContainer(for: [Document.self, Folder.self, Tag.self], inMemory: true)
}

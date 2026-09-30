import Foundation

/// Data the main app publishes for the widgets, via the App Group.
/// Compiled into both the app and the PDFWidgets target.
///
/// The app writes `recents.json` and small JPEG thumbnails whenever the
/// Library changes; the widget only ever reads. Kept deliberately tiny so
/// timeline reloads stay under WidgetKit's memory limit.
enum WidgetSnapshot {
    struct Recent: Codable, Identifiable, Hashable {
        var id: UUID
        var title: String
        var pageCount: Int
        var lastOpened: Date?
        /// File name of the thumbnail inside `thumbnailsURL`, if written.
        var thumbnail: String?

        var deepLink: URL { URL(string: "pdfeditor://document/\(id.uuidString)")! }
    }

    struct Payload: Codable {
        var updatedAt: Date
        var documentCount: Int
        var recents: [Recent]
    }

    /// Same group as `SharedInbox`; duplicated so the widget target only
    /// needs this one shared file.
    static let appGroupIdentifier = "group.com.wappltd.PDF-Reader"

    static let maxRecents = 6
    static let thumbnailMaxEdge: CGFloat = 160

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static var payloadURL: URL? {
        containerURL?.appending(path: "widget-recents.json")
    }

    static var thumbnailsURL: URL? {
        guard let containerURL else { return nil }
        let url = containerURL.appending(path: "WidgetThumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func read() -> Payload? {
        guard let payloadURL, let data = try? Data(contentsOf: payloadURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }

    static func write(_ payload: Payload) {
        guard let payloadURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(payload) {
            try? data.write(to: payloadURL, options: [.atomic])
        }
    }

    static func thumbnailURL(for recent: Recent) -> URL? {
        guard let name = recent.thumbnail, let thumbnailsURL else { return nil }
        return thumbnailsURL.appending(path: name)
    }
}

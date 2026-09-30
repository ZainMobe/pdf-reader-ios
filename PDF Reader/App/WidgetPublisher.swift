import Foundation
import SwiftData
import UIKit
import WidgetKit

/// Publishes Library recents to the App Group for the widgets and asks
/// WidgetKit to refresh. Cheap enough to call whenever the Library changes;
/// it debounces and does the image work off the main thread.
@MainActor
enum WidgetPublisher {
    private static var pending: Task<Void, Never>?

    static func schedule(from documents: [Document]) {
        // Snapshot model values now; nothing below touches SwiftData.
        let sorted = documents.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        let recents = sorted.prefix(WidgetSnapshot.maxRecents).map {
            (id: $0.id, title: $0.title, pageCount: $0.pageCount, lastOpened: $0.lastOpenedAt, thumb: $0.thumbnailData)
        }
        let total = documents.count

        pending?.cancel()
        pending = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let thumbsDir = WidgetSnapshot.thumbnailsURL else { return }

            var payloadRecents: [WidgetSnapshot.Recent] = []
            var keep = Set<String>()
            for item in recents {
                var name: String?
                if let data = item.thumb, let image = UIImage(data: data) {
                    let fileName = "\(item.id.uuidString).jpg"
                    let url = thumbsDir.appending(path: fileName)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        let small = image.preparingThumbnail(of: fitted(image.size, maxEdge: WidgetSnapshot.thumbnailMaxEdge)) ?? image
                        try? small.jpegData(compressionQuality: 0.7)?.write(to: url, options: [.atomic])
                    }
                    name = fileName
                    keep.insert(fileName)
                }
                payloadRecents.append(WidgetSnapshot.Recent(
                    id: item.id, title: item.title, pageCount: item.pageCount,
                    lastOpened: item.lastOpened, thumbnail: name
                ))
            }
            // Drop thumbnails for documents that fell out of the recents.
            if let files = try? FileManager.default.contentsOfDirectory(atPath: thumbsDir.path) {
                for file in files where !keep.contains(file) {
                    try? FileManager.default.removeItem(at: thumbsDir.appending(path: file))
                }
            }
            WidgetSnapshot.write(WidgetSnapshot.Payload(updatedAt: .now, documentCount: total, recents: payloadRecents))
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    nonisolated private static func fitted(_ size: CGSize, maxEdge: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxEdge, longest > 0 else { return size }
        let scale = maxEdge / longest
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

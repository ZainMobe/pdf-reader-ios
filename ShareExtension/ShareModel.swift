import Foundation
import ImageIO
import Observation
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Loads the shared attachments, stages them into the App Group inbox and
/// commits a manifest when the user taps Save.
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case ready
        case saving
        case saved
        case failed(String)
    }

    struct Row: Identifiable {
        let id = UUID()
        var title: String
        var kind: SharedInbox.ItemKind
        var storedName: String
        var thumbnail: UIImage?
        var byteCount: Int64
    }

    private(set) var phase: Phase = .loading
    private(set) var rows: [Row] = []
    /// Attachments that couldn't be read; shown as a footnote, never fatal
    /// unless every attachment failed.
    private(set) var skippedCount = 0

    var combineImages = true
    var combinedTitle = ""

    private let extensionItems: [NSExtensionItem]
    private let sourceAppName: String?
    private let onFinish: () -> Void
    private let onCancel: () -> Void

    private var batch: (id: String, url: URL)?

    init(
        extensionItems: [NSExtensionItem],
        sourceAppName: String?,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.extensionItems = extensionItems
        self.sourceAppName = sourceAppName
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    var imageCount: Int { rows.filter { $0.kind == .image }.count }
    var pdfCount: Int { rows.filter { $0.kind == .pdf }.count }
    var showsCombineOption: Bool { imageCount > 1 }

    var summary: String {
        var parts: [String] = []
        if pdfCount > 0 { parts.append(pdfCount == 1 ? "1 PDF" : "\(pdfCount) PDFs") }
        if imageCount > 0 { parts.append(imageCount == 1 ? "1 image" : "\(imageCount) images") }
        return parts.joined(separator: " and ")
    }

    // MARK: - Loading

    func load() async {
        guard SharedInbox.isAvailable else {
            phase = .failed(SharedInbox.InboxError.appGroupUnavailable.localizedDescription)
            return
        }
        do {
            batch = try SharedInbox.beginBatch()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        guard let batch else { return }

        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        var index = 0
        for provider in providers.prefix(SharedInbox.maxItemsPerBatch) {
            do {
                if let row = try await stage(provider, index: index, into: batch.url) {
                    rows.append(row)
                    index += 1
                } else {
                    skippedCount += 1
                }
            } catch {
                skippedCount += 1
            }
        }

        if rows.isEmpty {
            SharedInbox.discardBatch(at: batch.url)
            phase = .failed("Nothing shareable was found. PDF Editor accepts PDFs and images.")
        } else {
            if showsCombineOption, combinedTitle.isEmpty {
                combinedTitle = "Images · " + Date.now.formatted(date: .abbreviated, time: .shortened)
            }
            phase = .ready
        }
    }

    /// Copies one attachment into the batch folder. Returns nil for types we
    /// don't handle. Tries the file representation first (no memory cost),
    /// then an in-memory UIImage (screenshots, some photo pickers).
    private func stage(_ provider: NSItemProvider, index: Int, into batchURL: URL) async throws -> Row? {
        let suggested = provider.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? ""

        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            let storedName = "\(index).pdf"
            let destination = batchURL.appending(path: storedName)
            try await copyFileRepresentation(from: provider, type: .pdf, to: destination)
            guard let pdf = PDFDocument(url: destination) else {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
            let title = suggested.isEmpty ? (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "Document") : suggested
            let thumb = pdf.isLocked ? nil : pdf.page(at: 0)?.thumbnail(of: CGSize(width: 88, height: 116), for: .cropBox)
            return Row(title: title, kind: .pdf, storedName: storedName, thumbnail: thumb, byteCount: fileSize(destination))
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            // Prefer the on-disk representation: no decode, keeps HEIC as-is.
            let typeID = provider.registeredTypeIdentifiers
                .compactMap(UTType.init)
                .first { $0.conforms(to: .image) } ?? .image
            let ext = typeID.preferredFilenameExtension ?? "jpg"
            let storedName = "\(index).\(ext)"
            let destination = batchURL.appending(path: storedName)
            do {
                try await copyFileRepresentation(from: provider, type: typeID, to: destination)
            } catch {
                // Fall back to an in-memory image (e.g. a fresh screenshot).
                guard let image = try await loadUIImage(from: provider),
                      let data = image.jpegData(compressionQuality: 0.9) else { return nil }
                let jpgName = "\(index).jpg"
                try data.write(to: batchURL.appending(path: jpgName), options: [.atomic])
                let thumb = image.preparingThumbnail(of: CGSize(width: 88, height: 88))
                return Row(title: suggested.isEmpty ? "Image \(index + 1)" : suggested,
                           kind: .image, storedName: jpgName, thumbnail: thumb,
                           byteCount: Int64(data.count))
            }
            guard ImageThumb.canDecode(destination) else {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
            let thumb = ImageThumb.thumbnail(at: destination, maxPixel: 176)
            return Row(title: suggested.isEmpty ? "Image \(index + 1)" : suggested,
                       kind: .image, storedName: storedName, thumbnail: thumb,
                       byteCount: fileSize(destination))
        }

        return nil
    }

    private func copyFileRepresentation(from provider: NSItemProvider, type: UTType, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                // The URL is only valid inside this callback. Copy now.
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadUIImage(from provider: NSItemProvider) async throws -> UIImage? {
        guard provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - Actions

    func save() {
        guard case .ready = phase, let batch else { return }
        phase = .saving
        let manifest = SharedInbox.Manifest(
            batchID: batch.id,
            createdAt: .now,
            items: rows.map { SharedInbox.Item(storedName: $0.storedName, originalTitle: $0.title, kind: $0.kind) },
            combineImagesIntoOnePDF: combineImages,
            combinedTitle: combinedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceAppName: sourceAppName
        )
        do {
            try SharedInbox.commit(manifest, to: batch.url)
            phase = .saved
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                onFinish()
            }
        } catch {
            phase = .failed("Couldn't save: \(error.localizedDescription)")
        }
    }

    func cancel() {
        onCancel()
    }

    func discard() {
        if let batch { SharedInbox.discardBatch(at: batch.url) }
    }
}

/// Tiny ImageIO helper so the extension can preview without decoding
/// full-size bitmaps.
enum ImageThumb {
    static func canDecode(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    static func thumbnail(at url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

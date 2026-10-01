import Foundation
import Vision
import UIKit

/// Async OCR wrapper around Vision's `VNRecognizeTextRequest`.
enum OCRPipeline {
    /// One recognized text region with its normalized bounding box (Vision
    /// origin: bottom-left, 0-1 in image coordinates).
    struct RecognizedTextBox: Sendable {
        let string: String
        let boundingBox: CGRect
    }

    /// Upper bound on simultaneous `.accurate` recognitions. Each one holds
    /// a full-resolution bitmap plus Vision's working set; running every
    /// page of a 25-page scan at once spikes memory and throttles the device.
    private static let maxConcurrentRecognitions = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// Returns per-region recognition results, preserving bounding boxes
    /// (needed for the invisible-text overlay in scanned PDFs).
    static func recognizeDetailed(_ image: UIImage) async -> [RecognizedTextBox] {
        guard let cgImage = image.cgImage else { return [] }

        // Run synchronously on a background thread and read `results` after
        // `perform` returns. The completion-handler form resumed the
        // continuation from both the handler and the `catch` when Vision
        // reported an error through both channels, which traps.
        return await Task.detached(priority: .userInitiated) { () -> [RecognizedTextBox] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            let observations = request.results ?? []
            return observations.compactMap { observation -> RecognizedTextBox? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedTextBox(string: candidate.string, boundingBox: observation.boundingBox)
            }
        }.value
    }

    /// Returns concatenated text only — convenience for callers that don't
    /// care about bounding boxes.
    static func recognize(_ image: UIImage) async -> String {
        let boxes = await recognizeDetailed(image)
        return boxes.map(\.string).joined(separator: "\n")
    }

    /// Recognizes text in many images with bounded concurrency, preserving
    /// page order.
    static func recognizeAllDetailed(_ images: [UIImage]) async -> [[RecognizedTextBox]] {
        guard !images.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, [RecognizedTextBox]).self) { group in
            var results = [[RecognizedTextBox]](repeating: [], count: images.count)
            var next = 0

            func enqueue() {
                guard next < images.count else { return }
                let index = next
                let image = images[index]
                next += 1
                group.addTask { (index, await recognizeDetailed(image)) }
            }

            for _ in 0..<min(maxConcurrentRecognitions, images.count) {
                enqueue()
            }
            for await (index, boxes) in group {
                results[index] = boxes
                enqueue()
            }
            return results
        }
    }

    /// Concatenated plain text for all pages in order.
    static func recognizeAll(_ images: [UIImage]) async -> String {
        let detailed = await recognizeAllDetailed(images)
        return detailed
            .map { $0.map(\.string).joined(separator: "\n") }
            .joined(separator: "\n\n")
    }
}

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

    /// Returns per-region recognition results, preserving bounding boxes
    /// (needed for the invisible-text overlay in scanned PDFs).
    static func recognizeDetailed(_ image: UIImage) async -> [RecognizedTextBox] {
        guard let cgImage = image.cgImage else { return [] }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let boxes = observations.compactMap { observation -> RecognizedTextBox? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedTextBox(string: candidate.string, boundingBox: observation.boundingBox)
                }
                continuation.resume(returning: boxes)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    /// Returns concatenated text only — convenience for callers that don't
    /// care about bounding boxes.
    static func recognize(_ image: UIImage) async -> String {
        let boxes = await recognizeDetailed(image)
        return boxes.map(\.string).joined(separator: "\n")
    }

    /// Recognizes text in many images concurrently, preserving page order.
    static func recognizeAllDetailed(_ images: [UIImage]) async -> [[RecognizedTextBox]] {
        await withTaskGroup(of: (Int, [RecognizedTextBox]).self) { group in
            for (index, image) in images.enumerated() {
                group.addTask { (index, await recognizeDetailed(image)) }
            }
            var pieces: [(Int, [RecognizedTextBox])] = []
            for await item in group {
                pieces.append(item)
            }
            return pieces.sorted { $0.0 < $1.0 }.map(\.1)
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

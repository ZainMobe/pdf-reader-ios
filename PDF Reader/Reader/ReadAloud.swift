import Foundation
import AVFoundation
import PDFKit

/// Plays back PDF text via `AVSpeechSynthesizer`, page by page, with skip
/// forward/back and pause/resume. Auto-advances to the next page when the
/// current utterance finishes.
@MainActor
@Observable
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    enum State: Equatable { case idle, playing, paused }

    private(set) var state: State = .idle
    private(set) var currentPageIndex: Int = 0
    private(set) var totalPages: Int = 0

    private let synthesizer = AVSpeechSynthesizer()
    private var pages: [String] = []
    private let rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// Fires when the current page changes so the host can scroll the PDFView
    /// to match.
    var onPageChange: ((Int) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start(document: Document, fromPage pageIndex: Int) {
        guard let pdf = PDFDocument(url: document.fileURL) else { return }
        pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        totalPages = pages.count
        currentPageIndex = min(max(0, pageIndex), max(0, totalPages - 1))
        state = .playing
        speakCurrentPage()
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            synthesizer.pauseSpeaking(at: .word)
            state = .paused
        case .paused:
            synthesizer.continueSpeaking()
            state = .playing
        case .idle:
            break
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        state = .idle
    }

    func skipForward() {
        guard currentPageIndex + 1 < totalPages else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentPageIndex += 1
        onPageChange?(currentPageIndex)
        speakCurrentPage()
    }

    func skipBackward() {
        guard currentPageIndex > 0 else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentPageIndex -= 1
        onPageChange?(currentPageIndex)
        speakCurrentPage()
    }

    private func speakCurrentPage() {
        guard state != .idle, currentPageIndex < pages.count else {
            state = .idle
            return
        }
        let text = pages[currentPageIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            advanceFromDidFinish()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        synthesizer.speak(utterance)
    }

    private func advanceFromDidFinish() {
        if currentPageIndex + 1 < pages.count {
            currentPageIndex += 1
            onPageChange?(currentPageIndex)
            speakCurrentPage()
        } else {
            state = .idle
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.state == .playing else { return }
            self.advanceFromDidFinish()
        }
    }
}

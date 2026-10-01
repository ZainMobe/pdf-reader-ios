import AVFoundation
import Foundation
import MediaPlayer
import NaturalLanguage
import PDFKit
import UIKit

/// Plays back PDF text via `AVSpeechSynthesizer`, page by page, with skip
/// forward/back, pause/resume, adjustable speed and voice. Keeps playing
/// with the screen off and shows transport controls on the Lock Screen and
/// in Control Centre, so a long PDF works like an audiobook.
@MainActor
@Observable
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    enum State: Equatable { case idle, playing, paused }

    private(set) var state: State = .idle
    private(set) var currentPageIndex: Int = 0
    private(set) var totalPages: Int = 0
    private(set) var documentTitle = ""

    /// Speech rate multiplier shown to the user (0.5x to 2x). Persisted.
    var speed: Double {
        didSet {
            UserDefaults.standard.set(speed, forKey: Self.speedKey)
            if state != .idle { restartCurrentPage() }
        }
    }

    /// Voice identifier, nil = system default for the document language.
    var voiceIdentifier: String? {
        didSet {
            UserDefaults.standard.set(voiceIdentifier, forKey: Self.voiceKey)
            if state != .idle { restartCurrentPage() }
        }
    }

    static let speedKey = "settings.readAloud.speed"
    static let voiceKey = "settings.readAloud.voice"

    private let synthesizer = AVSpeechSynthesizer()
    private var pages: [String] = []
    private var detectedLanguage: String?
    private var remoteCommandsInstalled = false
    private var thumbnail: UIImage?
    /// Fires when the current page changes so the host can scroll the PDFView
    /// to match.
    var onPageChange: ((Int) -> Void)?

    override init() {
        let saved = UserDefaults.standard.double(forKey: Self.speedKey)
        speed = saved == 0 ? 1.0 : min(max(saved, 0.5), 2.0)
        voiceIdentifier = UserDefaults.standard.string(forKey: Self.voiceKey)
        super.init()
        synthesizer.delegate = self
    }

    /// Voices the user can pick from for the detected language, best first.
    var availableVoices: [AVSpeechSynthesisVoice] {
        let language = detectedLanguage ?? Locale.preferredLanguages.first ?? "en-US"
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    func start(document: Document, fromPage pageIndex: Int) {
        guard let pdf = PDFDocument.opened(at: document.fileURL), !pdf.isLocked else { return }
        pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        if pages.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
           let ocr = document.ocrText, !ocr.isEmpty {
            // Scanned document: read the OCR text as one long page.
            pages = [ocr]
        }
        totalPages = pages.count
        documentTitle = document.title
        currentPageIndex = min(max(0, pageIndex), max(0, totalPages - 1))
        detectedLanguage = Self.detectLanguage(in: pages.first(where: { $0.count > 40 }) ?? "")
        thumbnail = document.thumbnailData.flatMap(UIImage.init(data:))

        activateAudioSession()
        installRemoteCommands()
        state = .playing
        speakCurrentPage()
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            synthesizer.pauseSpeaking(at: .word)
            state = .paused
        case .paused:
            activateAudioSession()
            synthesizer.continueSpeaking()
            state = .playing
        case .idle:
            break
        }
        updateNowPlaying()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        state = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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

    // MARK: - Speaking

    /// Applies a new speed or voice immediately while playing. When paused
    /// the change simply takes effect on the next utterance.
    private func restartCurrentPage() {
        guard state == .playing else { return }
        synthesizer.stopSpeaking(at: .immediate)
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
        // AVSpeechUtteranceDefaultSpeechRate is 0.5 on a 0...1 scale; map the
        // user's 0.5x...2x onto the range the engine treats as natural.
        let base = AVSpeechUtteranceDefaultSpeechRate
        let clamped = Float(min(max(speed, 0.5), 2.0))
        utterance.rate = clamped <= 1
            ? base * clamped
            : base + (AVSpeechUtteranceMaximumSpeechRate - base) * ((clamped - 1) / 1.0) * 0.6
        utterance.voice = preferredVoice()
        utterance.postUtteranceDelay = 0.3
        synthesizer.speak(utterance)
        updateNowPlaying()
    }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        if let language = detectedLanguage, let voice = AVSpeechSynthesisVoice(language: language) { return voice }
        return AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
    }

    private func advanceFromDidFinish() {
        if currentPageIndex + 1 < pages.count {
            currentPageIndex += 1
            onPageChange?(currentPageIndex)
            speakCurrentPage()
        } else {
            stop()
        }
    }

    nonisolated private static func detectLanguage(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        return NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(1000)))?.rawValue
    }

    // MARK: - Background audio, Lock Screen

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.state == .paused { self?.togglePlayPause() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.state == .playing { self?.togglePlayPause() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard state != .idle else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: documentTitle,
            MPMediaItemPropertyArtist: "PDF Editor",
            MPMediaItemPropertyAlbumTitle: "Page \(currentPageIndex + 1) of \(totalPages)",
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? speed : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if totalPages > 0 {
            info[MPNowPlayingInfoPropertyChapterNumber] = currentPageIndex
            info[MPNowPlayingInfoPropertyChapterCount] = totalPages
        }
        if let thumbnail {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: thumbnail.size) { _ in thumbnail }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.state == .playing else { return }
            self.advanceFromDidFinish()
        }
    }
}

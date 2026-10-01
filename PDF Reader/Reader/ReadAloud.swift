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
    /// Remote-command targets registered by this instance. Removed in
    /// `stop()` so a new `ReadAloud` (one per Reader) doesn't stack targets
    /// on the shared command center.
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var thumbnail: UIImage?
    private var loadTask: Task<Void, Never>?
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
        loadTask?.cancel()
        let url = document.fileURL
        let ocrFallback = document.ocrText
        documentTitle = document.title
        thumbnail = document.thumbnailData.flatMap(UIImage.init(data:))

        // Show the transport controls right away; extracting the text of a
        // long PDF can take seconds and must not block the main thread.
        state = .playing
        totalPages = 0
        currentPageIndex = 0

        loadTask = Task { [weak self] in
            let extracted = await Task.detached(priority: .userInitiated) { () -> [String]? in
                guard let pdf = PDFDocument.opened(at: url), !pdf.isLocked else { return nil }
                var pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
                if pages.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                   let ocr = ocrFallback, !ocr.isEmpty {
                    // Scanned document: read the OCR text as one long page.
                    pages = [ocr]
                }
                return pages
            }.value
            guard let self, !Task.isCancelled, self.state != .idle else { return }
            guard let extracted, extracted.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                // Nothing to read (locked, unreadable, or image-only with no OCR).
                self.stop()
                return
            }
            self.pages = extracted
            self.totalPages = extracted.count
            self.currentPageIndex = min(max(0, pageIndex), max(0, self.totalPages - 1))
            self.detectedLanguage = Self.detectLanguage(in: extracted.first(where: { $0.count > 40 }) ?? "")

            self.activateAudioSession()
            self.installRemoteCommands()
            // If the user paused while the text was loading, wait for resume.
            if self.state == .playing {
                self.speakCurrentPage()
            } else {
                self.updateNowPlaying()
            }
        }
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            synthesizer.pauseSpeaking(at: .word)
            state = .paused
        case .paused:
            activateAudioSession()
            state = .playing
            if synthesizer.isPaused {
                synthesizer.continueSpeaking()
            } else {
                // Paused before the text finished loading: nothing is queued
                // yet, so start the current page instead of resuming.
                speakCurrentPage()
            }
        case .idle:
            break
        }
        updateNowPlaying()
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        state = .idle
        removeRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func skipForward() {
        guard currentPageIndex + 1 < totalPages else { return }
        skip(to: currentPageIndex + 1)
    }

    func skipBackward() {
        guard currentPageIndex > 0 else { return }
        skip(to: currentPageIndex - 1)
    }

    /// `stopSpeaking` clears any pause, so skipping while paused resumes
    /// playback; reflect that in `state` so the controls don't show "Paused"
    /// while audio is playing.
    private func skip(to index: Int) {
        synthesizer.stopSpeaking(at: .immediate)
        currentPageIndex = index
        onPageChange?(currentPageIndex)
        if state == .paused { state = .playing }
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
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, _ handler: @escaping @MainActor (ReadAloud) -> Void) {
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    handler(self)
                }
                return .success
            }
            remoteCommandTargets.append((command, token))
        }
        register(center.playCommand) { if $0.state == .paused { $0.togglePlayPause() } }
        register(center.pauseCommand) { if $0.state == .playing { $0.togglePlayPause() } }
        register(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        register(center.nextTrackCommand) { $0.skipForward() }
        register(center.previousTrackCommand) { $0.skipBackward() }
        register(center.stopCommand) { $0.stop() }
    }

    private func removeRemoteCommands() {
        for (command, token) in remoteCommandTargets {
            command.removeTarget(token)
        }
        remoteCommandTargets.removeAll()
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

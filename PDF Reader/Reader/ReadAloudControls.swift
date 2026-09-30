import AVFoundation
import SwiftUI

/// Glass mini-player pinned to the bottom of the Reader while read-aloud is
/// active. Tap-and-hold targets are large enough to be usable while walking.
struct ReadAloudControls: View {
    @Bindable var aloud: ReadAloud

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.l) {
            Button {
                aloud.skipBackward()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
            }
            .disabled(aloud.currentPageIndex == 0)

            Button {
                aloud.togglePlayPause()
            } label: {
                Image(systemName: aloud.state == .playing ? "pause.fill" : "play.fill")
                    .font(.title)
            }

            Button {
                aloud.skipForward()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .disabled(aloud.currentPageIndex >= max(0, aloud.totalPages - 1))

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Page \(aloud.currentPageIndex + 1) of \(aloud.totalPages)")
                    .font(.caption)
                Text(aloud.state == .paused ? "Paused" : "Reading aloud")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Menu {
                Section("Speed") {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { value in
                        Button {
                            aloud.speed = value
                        } label: {
                            if abs(aloud.speed - value) < 0.01 {
                                Label(speedLabel(value), systemImage: "checkmark")
                            } else {
                                Text(speedLabel(value))
                            }
                        }
                    }
                }
                Section("Voice") {
                    Button {
                        aloud.voiceIdentifier = nil
                    } label: {
                        if aloud.voiceIdentifier == nil {
                            Label("Automatic", systemImage: "checkmark")
                        } else {
                            Text("Automatic")
                        }
                    }
                    ForEach(aloud.availableVoices.prefix(12), id: \.identifier) { voice in
                        Button {
                            aloud.voiceIdentifier = voice.identifier
                        } label: {
                            if aloud.voiceIdentifier == voice.identifier {
                                Label(voiceLabel(voice), systemImage: "checkmark")
                            } else {
                                Text(voiceLabel(voice))
                            }
                        }
                    }
                }
            } label: {
                Text(speedLabel(aloud.speed))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.fill.tertiary))
            }

            Button {
                aloud.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.l)
        .padding(.vertical, DesignSystem.Spacing.m)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.large))
        .padding(.horizontal, DesignSystem.Spacing.l)
        .padding(.bottom, DesignSystem.Spacing.l)
    }

    private func speedLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + "x"
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium: quality = " (Premium)"
        case .enhanced: quality = " (Enhanced)"
        default: quality = ""
        }
        return voice.name + quality
    }
}

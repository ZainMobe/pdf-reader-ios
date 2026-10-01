import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UIKit

/// Payload for `ExportResultView`: one or more files produced by a tool that
/// don't become Library documents (Word/text exports, page images).
struct ExportResult {
    var title: String
    var summary: String
    var files: [URL]
    /// Optional plain-text excerpt shown under the preview (text exports).
    var textExcerpt: String?
    /// Free-tier allowance this result consumes; `nil` for free tools.
    var meteredFeature: ProFeature? = .tool

    var totalBytes: Int64 {
        files.reduce(0) { total, url in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        }
    }
}

/// In-sheet result screen for file exports. Mirrors `ToolSuccessView` (which
/// is for results that land in the Library) so every tool ends the same way:
/// a clear "done" state with a preview and the ways to get the file out.
///
/// The preview is a QuickLook thumbnail (Word, text and images all render);
/// tapping it opens the full QuickLook viewer, which can page through every
/// exported file.
struct ExportResultView: View {
    let result: ExportResult
    let onDone: () -> Void
    var onExportAnother: (() -> Void)? = nil
    /// Optional extra action, e.g. "Save to Photos" for image exports.
    var secondaryAction: SecondaryAction? = nil

    struct SecondaryAction {
        var title: String
        var systemImage: String
        var action: () -> Void
    }

    @Environment(\.displayScale) private var displayScale

    @State private var thumbnail: UIImage?
    @State private var thumbnailFailed = false
    @State private var previewItem: URL?
    @State private var showingShare = false
    @State private var showingFilesExport = false
    @State private var checkmarkScale: CGFloat = 0.3
    @State private var checkmarkOpacity: Double = 0
    @State private var contentOpacity: Double = 0

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.xl) {
                successBadge
                    .padding(.top, DesignSystem.Spacing.xl)

                VStack(spacing: DesignSystem.Spacing.s) {
                    Text(result.title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(result.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .opacity(contentOpacity)
                .padding(.horizontal, DesignSystem.Spacing.l)

                previewCard
                    .opacity(contentOpacity)
                    .padding(.horizontal, DesignSystem.Spacing.l)

                if let excerpt = result.textExcerpt, !excerpt.isEmpty {
                    excerptCard(excerpt)
                        .opacity(contentOpacity)
                        .padding(.horizontal, DesignSystem.Spacing.l)
                }

                actions
                    .opacity(contentOpacity)
                    .padding(.horizontal, DesignSystem.Spacing.l)
                    .padding(.bottom, DesignSystem.Spacing.xl)
            }
        }
        .quickLookPreview($previewItem, in: result.files)
        .sheet(isPresented: $showingShare) {
            ActivityShareSheet(items: result.files)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingFilesExport) {
            FilesExportPicker(urls: result.files)
                .ignoresSafeArea()
        }
        .task(id: result.files.first) { await loadThumbnail() }
        .onAppear {
            Haptics.success()
            if let feature = result.meteredFeature {
                EntitlementStore.shared.recordUse(feature)
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                checkmarkScale = 1.0
                checkmarkOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.15)) {
                contentOpacity = 1.0
            }
        }
    }

    // MARK: - Pieces

    private var successBadge: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 96, height: 96)
            Circle()
                .stroke(Color.green.opacity(0.35), lineWidth: 2)
                .frame(width: 96, height: 96)
            Image(systemName: "checkmark")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.green)
                .scaleEffect(checkmarkScale)
                .opacity(checkmarkOpacity)
        }
    }

    private var primaryFile: URL? { result.files.first }

    private var previewCard: some View {
        Button {
            previewItem = primaryFile
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    Rectangle()
                        .fill(Color(uiColor: .secondarySystemBackground))
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .padding(DesignSystem.Spacing.m)
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    } else if thumbnailFailed {
                        Image(systemName: fileIcon)
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                    } else {
                        ProgressView()
                    }
                }
                .frame(height: 260)
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                        Text(result.files.count > 1 ? "Preview \(result.files.count) files" : "Preview")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, DesignSystem.Spacing.m)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(DesignSystem.Spacing.m)
                }

                HStack(spacing: DesignSystem.Spacing.m) {
                    Image(systemName: fileIcon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fileLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(DesignSystem.Spacing.m)
            }
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.medium, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemBackground))
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.medium, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview \(fileLabel)")
    }

    private func excerptCard(_ excerpt: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Text preview")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(excerpt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignSystem.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.medium, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var actions: some View {
        VStack(spacing: DesignSystem.Spacing.s) {
            Button {
                Haptics.impact(.light)
                showingShare = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.m)
            }
            .buttonStyle(.glassProminent)

            HStack(spacing: DesignSystem.Spacing.s) {
                Button {
                    Haptics.impact(.light)
                    showingFilesExport = true
                } label: {
                    Label("Save to Files", systemImage: "folder")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.Spacing.s)
                }
                .buttonStyle(.glass)

                if let secondaryAction {
                    Button {
                        Haptics.impact(.light)
                        secondaryAction.action()
                    } label: {
                        Label(secondaryAction.title, systemImage: secondaryAction.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignSystem.Spacing.s)
                    }
                    .buttonStyle(.glass)
                }
            }

            if let onExportAnother {
                Button("Export Another") {
                    Haptics.selection()
                    onExportAnother()
                }
                .font(.subheadline)
                .padding(.top, DesignSystem.Spacing.xs)
            }

            Button("Done") {
                Haptics.impact(.light)
                onDone()
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private var fileIcon: String {
        switch primaryFile?.pathExtension.lowercased() ?? "" {
        case "docx", "doc": "doc.richtext"
        case "txt": "doc.plaintext"
        case "jpg", "jpeg", "png", "heic": "photo"
        case "pdf": "doc.fill"
        default: "doc"
        }
    }

    private var fileLabel: String {
        guard let primaryFile else { return "" }
        if result.files.count == 1 { return primaryFile.lastPathComponent }
        return "\(result.files.count) files · \(primaryFile.lastPathComponent) …"
    }

    // MARK: - Thumbnail

    private func loadThumbnail() async {
        thumbnail = nil
        thumbnailFailed = false
        guard let url = primaryFile else {
            thumbnailFailed = true
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 360, height: 480),
            scale: displayScale,
            representationTypes: .thumbnail
        )
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            thumbnail = representation.uiImage
        } catch {
            thumbnailFailed = true
        }
    }
}

/// "Save to Files" for files that aren't Library documents. Exports a copy,
/// so the temp originals can be cleaned up afterwards.
struct FilesExportPicker: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

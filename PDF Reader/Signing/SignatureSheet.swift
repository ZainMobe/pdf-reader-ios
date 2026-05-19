import SwiftUI
import SwiftData
import PencilKit
import PhotosUI
import UIKit

/// Sheet for picking an existing signature or creating a new one via three
/// methods — draw, type, or import from Photos. On selection, the chosen
/// signature image is handed back via `onSelect` and the sheet dismisses.
struct SignatureSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SignatureAsset.createdAt, order: .reverse) private var signatures: [SignatureAsset]

    let onSelect: (UIImage) -> Void

    @State private var isCreating = false
    @State private var creationMode: CreationMode = .draw
    @State private var canvasView = PKCanvasView()
    @State private var drawingIsEmpty = true
    @State private var typedText: String = ""
    @State private var typedFont: String = SignatureSheet.cursiveFonts[0]
    @State private var pickedItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?

    enum CreationMode: String, CaseIterable, Identifiable {
        case draw, type, importPhoto
        var id: Self { self }
        var title: String {
            switch self {
            case .draw: "Draw"
            case .type: "Type"
            case .importPhoto: "Import"
            }
        }
    }

    static let cursiveFonts = [
        "SnellRoundhand",
        "SnellRoundhand-Bold",
        "Savoye-LET",
        "Apple-Chancery",
        "Zapfino",
    ]

    var body: some View {
        NavigationStack {
            Group {
                if isCreating || signatures.isEmpty {
                    creationSurface
                } else {
                    savedList
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isCreating && !signatures.isEmpty ? "Back" : "Cancel") {
                        if isCreating && !signatures.isEmpty {
                            isCreating = false
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isCreating || signatures.isEmpty {
                        Button("Save & Place") { saveAndPlace() }
                            .buttonStyle(.glassProminent)
                            .disabled(!canCommit)
                    } else {
                        Button {
                            isCreating = true
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                    }
                }
            }
        }
    }

    private var navigationTitle: String {
        if isCreating || signatures.isEmpty { return "New Signature" }
        return "Sign Document"
    }

    // MARK: - Saved list

    private var savedList: some View {
        List {
            ForEach(signatures) { sig in
                Button {
                    place(sig)
                } label: {
                    HStack(spacing: DesignSystem.Spacing.m) {
                        if let image = UIImage(data: sig.imageData) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 40)
                        }
                        VStack(alignment: .leading) {
                            Text(sig.name)
                                .font(.headline)
                            Text(sig.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for index in offsets {
                    modelContext.delete(signatures[index])
                }
            }
        }
    }

    // MARK: - Creation

    private var creationSurface: some View {
        VStack(spacing: DesignSystem.Spacing.m) {
            Picker("Mode", selection: $creationMode) {
                ForEach(CreationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch creationMode {
            case .draw: drawingSurface
            case .type: typingSurface
            case .importPhoto: importSurface
            }
        }
        .padding(DesignSystem.Spacing.l)
    }

    private var drawingSurface: some View {
        VStack(spacing: DesignSystem.Spacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.medium)
                    .fill(.background.secondary)
                SignatureCanvasView(canvasView: $canvasView) { drawing in
                    drawingIsEmpty = drawing.bounds.isEmpty
                }
                .padding(DesignSystem.Spacing.m)
                if drawingIsEmpty {
                    Text("Sign here")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)

            HStack {
                Button("Clear") {
                    canvasView.drawing = PKDrawing()
                    drawingIsEmpty = true
                }
                Spacer()
            }
        }
    }

    private var typingSurface: some View {
        VStack(spacing: DesignSystem.Spacing.l) {
            TextField("Your name", text: $typedText)
                .textFieldStyle(.roundedBorder)
                .font(.title2)

            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.medium)
                    .fill(.background.secondary)
                if typedText.isEmpty {
                    Text("Preview")
                        .foregroundStyle(.tertiary)
                } else {
                    Text(typedText)
                        .font(Font.custom(typedFont, size: 48))
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 160)

            Picker("Font", selection: $typedFont) {
                ForEach(Self.cursiveFonts, id: \.self) { font in
                    Text(font.replacingOccurrences(of: "-", with: " "))
                        .font(Font.custom(font, size: 18))
                        .tag(font)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var importSurface: some View {
        VStack(spacing: DesignSystem.Spacing.l) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.medium)
                    .fill(.background.secondary)
                if let pickedImage {
                    Image(uiImage: pickedImage)
                        .resizable()
                        .scaledToFit()
                        .padding(DesignSystem.Spacing.m)
                } else {
                    VStack(spacing: DesignSystem.Spacing.s) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("Pick a photo of your signature")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)

            PhotosPicker(
                selection: $pickedItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label(pickedImage == nil ? "Choose Photo" : "Replace Photo", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.glass)
            .onChange(of: pickedItem) { _, newItem in
                Task { await loadPickedImage(newItem) }
            }
        }
    }

    // MARK: - Commit

    private var canCommit: Bool {
        switch creationMode {
        case .draw: !drawingIsEmpty
        case .type: !typedText.trimmingCharacters(in: .whitespaces).isEmpty
        case .importPhoto: pickedImage != nil
        }
    }

    private func saveAndPlace() {
        guard let image = currentImage() else {
            dismiss()
            return
        }
        let asset = SignatureAsset(
            name: defaultName(),
            imageData: image.pngData() ?? Data()
        )
        modelContext.insert(asset)
        onSelect(image)
        dismiss()
    }

    private func place(_ asset: SignatureAsset) {
        guard let image = UIImage(data: asset.imageData) else { return }
        onSelect(image)
        dismiss()
    }

    private func currentImage() -> UIImage? {
        switch creationMode {
        case .draw:
            let drawingBounds = canvasView.drawing.bounds
            guard !drawingBounds.isEmpty else { return nil }
            return canvasView.drawing.image(from: drawingBounds, scale: 3.0)
        case .type:
            return renderTypedSignature()
        case .importPhoto:
            return pickedImage
        }
    }

    private func renderTypedSignature() -> UIImage? {
        let trimmed = typedText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let font = UIFont(name: typedFont, size: 96) ?? UIFont.systemFont(ofSize: 96, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
        ]
        let attributed = NSAttributedString(string: trimmed, attributes: attrs)
        let textSize = attributed.size()
        let padding: CGFloat = 24
        let renderSize = CGSize(
            width: ceil(textSize.width) + padding * 2,
            height: ceil(textSize.height) + padding * 2
        )
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        return renderer.image { _ in
            attributed.draw(at: CGPoint(x: padding, y: padding))
        }
    }

    private func defaultName() -> String {
        switch creationMode {
        case .draw: "Drawn Signature \(signatures.count + 1)"
        case .type: typedText.trimmingCharacters(in: .whitespaces)
        case .importPhoto: "Imported Signature \(signatures.count + 1)"
        }
    }

    private func loadPickedImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            pickedImage = image
        }
    }
}

import SwiftUI
import PDFKit
import UIKit

/// Full-screen placement editor for a signature image. Renders the target
/// page asynchronously as a background and lets the user drag the signature
/// around, pinch to resize, and rotate with two fingers before stamping it
/// as a `PDFAnnotation`.
///
/// The host (Reader) receives the final placement as a `CGRect` in PDF page
/// coordinates plus a rotation in degrees, and stamps the annotation via
/// `ReaderController.placeSignature`.
struct SignaturePlacementSheet: View {
    let document: Document
    let pageIndex: Int
    let signatureImage: UIImage
    let onPlace: (CGRect, CGFloat) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pageImage: UIImage?
    @State private var pageSize: CGSize = .zero
    @State private var didLoadPage = false

    /// Position + size + rotation are stored separately from the live gesture
    /// values so we can commit them on end while still rendering smoothly
    /// during the drag/pinch/rotate gestures.
    @State private var centerXNorm: CGFloat = 0.5
    @State private var centerYNorm: CGFloat = 0.78
    @State private var widthNorm: CGFloat = 0.33
    @State private var rotationDegrees: CGFloat = 0
    /// Snapshot of `widthNorm` taken on the first frame of a corner-handle
    /// drag so subsequent translation values resize from the original size
    /// instead of compounding.
    @State private var resizeStartWidthNorm: CGFloat?

    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var liveMagnification: CGFloat = 1.0
    @GestureState private var liveRotation: Angle = .zero

    private var aspect: CGFloat {
        signatureImage.size.height / max(signatureImage.size.width, 1)
    }

    /// Stable coordinate space for drag gestures. Reading translation in
    /// this space (anchored to the placement view, which doesn't move)
    /// avoids the feedback loop where the dragged view follows the finger,
    /// which moves the gesture's local coord space, which alters the next
    /// translation reading — producing visible jitter.
    private static let placementSpace = "placement"

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let fit = aspectFit(pageSize, in: proxy.size)
                let pageRect = CGRect(
                    x: (proxy.size.width - fit.width) / 2,
                    y: (proxy.size.height - fit.height) / 2,
                    width: fit.width,
                    height: fit.height
                )

                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    if let pageImage {
                        Image(uiImage: pageImage)
                            .resizable()
                            .frame(width: fit.width, height: fit.height)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        signatureOverlay(in: pageRect)
                    } else {
                        VStack(spacing: DesignSystem.Spacing.m) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Preparing page…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(DesignSystem.Spacing.xl)
                        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
                    }

                    if didLoadPage {
                        VStack {
                            Spacer()
                            sizeSliderPanel
                                .padding(.horizontal, DesignSystem.Spacing.l)
                                .padding(.bottom, DesignSystem.Spacing.l)
                        }
                    }
                }
                .coordinateSpace(.named(Self.placementSpace))
            }
            .navigationTitle("Place Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        Haptics.selection()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Place") { commit() }
                        .buttonStyle(.glassProminent)
                        .disabled(!didLoadPage)
                }
            }
            .task { await renderPage() }
        }
    }

    private func signatureOverlay(in pageRect: CGRect) -> some View {
        let liveWidth = pageRect.width * widthNorm * liveMagnification
        let liveHeight = liveWidth * aspect
        let centerX = pageRect.minX + pageRect.width * centerXNorm + dragOffset.width
        let centerY = pageRect.minY + pageRect.height * centerYNorm + dragOffset.height
        let totalRotation = Angle(degrees: rotationDegrees) + liveRotation

        let dragGesture = DragGesture(coordinateSpace: .named(Self.placementSpace))
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                guard pageRect.width > 0, pageRect.height > 0 else { return }
                let dx = value.translation.width / pageRect.width
                let dy = value.translation.height / pageRect.height
                centerXNorm = clamp(centerXNorm + dx, 0.05, 0.95)
                centerYNorm = clamp(centerYNorm + dy, 0.05, 0.95)
            }

        let magnifyGesture = MagnificationGesture()
            .updating($liveMagnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                widthNorm = clamp(widthNorm * value, 0.1, 0.9)
            }

        let rotateGesture = RotationGesture()
            .updating($liveRotation) { value, state, _ in
                state = value
            }
            .onEnded { value in
                rotationDegrees += CGFloat(value.degrees)
                Haptics.selection()
            }

        return ZStack {
            Image(uiImage: signatureImage)
                .resizable()
                .scaledToFit()
                .frame(width: liveWidth, height: liveHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                        .strokeBorder(.tint, lineWidth: 1.5)
                )
                .gesture(
                    SimultaneousGesture(
                        SimultaneousGesture(dragGesture, magnifyGesture),
                        rotateGesture
                    )
                )

            ForEach(SignatureCorner.allCases) { corner in
                resizeHandle(
                    corner: corner,
                    frameWidth: liveWidth,
                    frameHeight: liveHeight,
                    pageWidth: pageRect.width
                )
            }
        }
        .frame(width: liveWidth, height: liveHeight)
        .rotationEffect(totalRotation)
        .position(x: centerX, y: centerY)
    }

    private var sizeSliderPanel: some View {
        HStack(spacing: DesignSystem.Spacing.m) {
            Image(systemName: "minus.magnifyingglass")
                .foregroundStyle(.secondary)
            Slider(value: $widthNorm, in: 0.1...0.9)
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DesignSystem.Spacing.m)
        .padding(.vertical, DesignSystem.Spacing.s)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignSystem.Radius.medium))
    }

    private func resizeHandle(
        corner: SignatureCorner,
        frameWidth: CGFloat,
        frameHeight: CGFloat,
        pageWidth: CGFloat
    ) -> some View {
        let outwardX = corner.outwardX
        let outwardY = corner.outwardY
        let offsetX = (frameWidth / 2) * outwardX
        let offsetY = (frameHeight / 2) * outwardY

        return Circle()
            .fill(Color(.systemBackground))
            .overlay(Circle().strokeBorder(.tint, lineWidth: 2))
            .frame(width: 22, height: 22)
            .offset(x: offsetX, y: offsetY)
            .gesture(
                DragGesture(coordinateSpace: .named(Self.placementSpace))
                    .onChanged { value in
                        if resizeStartWidthNorm == nil {
                            resizeStartWidthNorm = widthNorm
                        }
                        let start = resizeStartWidthNorm ?? widthNorm
                        guard pageWidth > 0 else { return }
                        let dx = value.translation.width * outwardX
                        let dyAsX = aspect > 0
                            ? (value.translation.height * outwardY / aspect)
                            : 0
                        let avgDelta = (dx + dyAsX) / 2
                        let newPixelWidth = start * pageWidth + 2 * avgDelta
                        widthNorm = clamp(newPixelWidth / pageWidth, 0.1, 0.9)
                    }
                    .onEnded { _ in
                        resizeStartWidthNorm = nil
                        Haptics.selection()
                    }
            )
    }

    /// Loads the PDF and renders the target page on a background priority
    /// task. The placement preview only needs to be readable, not crisp —
    /// the actual signature is rendered at vector quality on commit — so
    /// we render at native 72 DPI (scale 1.0). At scale 2 on a large PDF
    /// this could take 5-8 seconds and froze the sheet in a "blank" state.
    private func renderPage() async {
        let url = document.fileURL
        let idx = pageIndex
        let result: (CGSize, UIImage?)? = await Task.detached(priority: .userInitiated) {
            guard
                let pdf = PDFDocument(url: url),
                let page = pdf.page(at: idx)
            else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let image = page.thumbnail(of: bounds.size, for: .cropBox)
            return (bounds.size, image)
        }.value

        if let result {
            pageSize = result.0
            pageImage = result.1
            didLoadPage = true
        }
    }

    private func commit() {
        guard
            let pdf = PDFDocument(url: document.fileURL),
            let page = pdf.page(at: pageIndex)
        else {
            dismiss()
            return
        }
        let bounds = page.bounds(for: .mediaBox)
        let sigWidth = bounds.width * widthNorm
        let sigHeight = sigWidth * aspect

        // Normalized Y is top-down; PDF page space is bottom-up.
        let centerX = bounds.width * centerXNorm
        let centerYFromTop = bounds.height * centerYNorm
        let centerYFromBottom = bounds.height - centerYFromTop

        let placedBounds = CGRect(
            x: centerX - sigWidth / 2,
            y: centerYFromBottom - sigHeight / 2,
            width: sigWidth,
            height: sigHeight
        )
        Haptics.impact(.medium)
        onPlace(placedBounds, rotationDegrees)
        dismiss()
    }

    private func aspectFit(_ source: CGSize, in container: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return container }
        let ratio = min(container.width / source.width, container.height / source.height)
        return CGSize(width: source.width * ratio, height: source.height * ratio)
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}

private enum SignatureCorner: CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: Self { self }

    var outwardX: CGFloat {
        switch self {
        case .topLeft, .bottomLeft: -1
        case .topRight, .bottomRight: 1
        }
    }

    var outwardY: CGFloat {
        switch self {
        case .topLeft, .topRight: -1
        case .bottomLeft, .bottomRight: 1
        }
    }
}

import SwiftUI
import VisionKit
import AVFoundation
import UIKit

/// SwiftUI wrapper for `VNDocumentCameraViewController`.
///
/// Returns the captured pages as an array of `UIImage`s via `onCompletion`.
/// Cancel returns `success([])`. Prefer presenting `ScannerLauncher` rather
/// than this view directly — `ScannerLauncher` probes camera permission
/// first and shows a graceful "open Settings" state when access is denied.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onCompletion: (Result<[UIImage], any Error>) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onCompletion: (Result<[UIImage], any Error>) -> Void

        init(onCompletion: @escaping (Result<[UIImage], any Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var images: [UIImage] = []
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            onCompletion(.success(images))
            controller.dismiss(animated: true)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCompletion(.success([]))
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: any Error
        ) {
            onCompletion(.failure(error))
            controller.dismiss(animated: true)
        }
    }
}

/// Probes camera permission before presenting the scanner. If permission was
/// denied or restricted, shows a recovery screen with a deep-link to Settings.
struct ScannerLauncher: View {
    let onCompletion: (Result<[UIImage], any Error>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            switch status {
            case .authorized:
                DocumentScannerView { result in
                    onCompletion(result)
                    dismiss()
                }
                .ignoresSafeArea()
            case .denied, .restricted:
                deniedState
            case .notDetermined:
                ProgressView()
                    .task { await requestAccess() }
            @unknown default:
                deniedState
            }
        }
    }

    private var deniedState: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: DesignSystem.Spacing.l) {
                ContentUnavailableView {
                    Label("Camera Access Needed", systemImage: "camera.fill")
                } description: {
                    Text("PDF AI needs camera access to scan paper documents. Turn it on in Settings to continue.")
                }
                HStack(spacing: DesignSystem.Spacing.s) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.glass)
                    Button("Open Settings") { openSettings() }
                        .buttonStyle(.glassProminent)
                }
            }
            .padding(DesignSystem.Spacing.xl)
        }
    }

    private func requestAccess() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        status = granted ? .authorized : .denied
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#if os(iOS)
import AVFoundation
import SwiftUI
import VisionKit

struct PairingScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraAllowed: Bool?

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    ContentUnavailableView("QR scanning unavailable", systemImage: "qrcode.viewfinder",
                                           description: Text("This iPhone does not support live QR scanning."))
                } else if cameraAllowed == false {
                    ContentUnavailableView("Camera access needed", systemImage: "camera.fill",
                                           description: Text("Allow camera access for HerdrWatch in Settings, then scan the pairing QR again."))
                } else if cameraAllowed == true && DataScannerViewController.isAvailable {
                    PairingScannerCamera(onCode: { value in
                        onCode(value)
                        dismiss()
                    })
                    .overlay(alignment: .bottom) {
                        Label("Point at the QR code shown by herdrwatch-host", systemImage: "qrcode.viewfinder")
                            .font(.subheadline.weight(.medium)).padding(14)
                            .frame(maxWidth: .infinity)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(20)
                    }
                    .ignoresSafeArea()
                } else {
                    ProgressView("Preparing camera…")
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: cameraAllowed = true
            case .notDetermined: cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
            default: cameraAllowed = false
            }
        }
    }
}

private struct PairingScannerCamera: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var scanned = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !scanned, let value = addedItems.compactMap({ item -> String? in
                if case .barcode(let code) = item { return code.payloadStringValue }
                return nil
            }).first else { return }
            scanned = true
            onCode(value)
        }
    }
}
#endif

//
//  SPECTRE Capture — one-time individual enrolment by QR code or link.
//  The QR or link is spectre://enroll?v=1&endpoint=…&code=…, or the shareable
//  https://script.google.com/macros/s/<id>/exec?i=<code> (single use, expires).
//

import SwiftUI
import UIKit
import AVFoundation

struct SpectreEnrollmentView: View {
    @ObservedObject var service: SpectreDepositService
    @Environment(\.presentationMode) private var presentation
    @State private var manual = ""
    @State private var busy = false
    @State private var done = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Scannez l'invitation personnelle remise par le responsable. Elle ne fonctionne qu'une fois.")
                    .multilineTextAlignment(.center)
                SpectreQRScanner { code in submit(code) }
                    .frame(height: 260).overlay(Rectangle().stroke(Color.white, lineWidth: 1))
                TextField("…ou collez le lien d'invitation", text: $manual)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                Button("Valider") { submit(manual) }.disabled(manual.isEmpty || busy)
                if busy { ProgressView() }
                if let e = service.lastEnrollmentError { Text(e).foregroundColor(.red) }
                if done { Text("Appareil configuré. Vous pouvez filmer.").foregroundColor(.white) }
                Spacer()
            }
            .padding()
            .navigationTitle("Configuration")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { presentation.wrappedValue.dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
    }

    private func submit(_ text: String) {
        guard !busy else { return }
        busy = true
        Task {
            let ok = await service.enroll(with: text)
            await MainActor.run { busy = false; done = ok; if ok { presentation.wrappedValue.dismiss() } }
        }
    }
}

/// Minimal AVFoundation QR reader (no third-party dependency, no network).
struct SpectreQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerVC { let vc = ScannerVC(); vc.onCode = onCode; return vc }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first?.frame = view.bounds
        }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); session.stopRunning() }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  s.hasPrefix("spectre://enroll") || s.hasPrefix("https://script.google.com/macros/s/") else { return }
            delivered = true
            onCode?(s)
        }
    }
}

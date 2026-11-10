//
//  SPECTRE Capture — the iPhone's own camera screen (UIImagePickerController),
//  as requested by the owner instead of Tella's custom camera.
//  Opens in video mode. Nothing is written to the Photos library: the file
//  returned by iOS is copied to Tella's temp area, encrypted into the vault,
//  then handed to the SPECTRE deposit (videos) exactly like Tella's camera did.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Camera tab: the system camera, recreated after each capture so it is back on
/// the live view for the next shot (an embedded picker otherwise stays on review).
struct SpectreSystemCameraScreen: View {
    let mainAppModel: MainAppModel
    @State private var generation = 0

    var body: some View {
        SpectreSystemCamera(mainAppModel: mainAppModel,
                            onCaptured: { generation += 1 },
                            onClose: { mainAppModel.selectedTab = .home })
            .id(generation)
            .background(Color.black)
            .edgesIgnoringSafeArea(.all)
    }
}

struct SpectreSystemCamera: UIViewControllerRepresentable {
    let mainAppModel: MainAppModel
    /// Called after a photo or video was handed to the vault.
    let onCaptured: () -> Void
    /// Called when the user taps Cancel.
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return picker }
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier, UTType.image.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 4 * 60 * 60   // default is 10 min: far too short for a demonstration
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: SpectreSystemCamera
        init(_ parent: SpectreSystemCamera) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let app = parent.mainAppModel
            if let movie = info[.mediaURL] as? URL {
                // iOS deletes its own temp file after this call: copy it first.
                let ext = movie.pathExtension.isEmpty ? "mov" : movie.pathExtension.lowercased()
                let dest = app.vaultManager.createTempFileURL(pathExtension: ext)
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: movie, to: dest)
                    try? FileManager.default.removeItem(at: movie)
                    import_(dest, app)
                } catch {
                    Toast.displayToast(message: LocalizableCommon.commonError.localized)
                }
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
                let dest = app.vaultManager.createTempFileURL(pathExtension: "jpg")
                if (try? data.write(to: dest, options: .completeFileProtection)) != nil { import_(dest, app) }
            }
            // Back to the live camera for the next shot, like the Camera app.
            parent.onCaptured()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onClose()
        }

        private func import_(_ url: URL, _ app: MainAppModel) {
            let file = ImportedFile(urlFile: url,
                                    parentId: nil,
                                    shouldPreserveMetadata: app.settings.preserveMetadata,
                                    fileSource: .camera)
            app.addVaultFile(importedFiles: [file], autoUpload: false)
        }
    }
}

import PhotosUI
import SwiftUI

// SwiftUI host for PHPickerViewController. PHPicker is the right v1
// affordance for attachments because it runs out-of-process and doesn't
// need Photos library permission — the user picks specific items and we
// receive only those. Multi-select is on (selectionLimit: 6) so logging
// a session's worth of clips is one trip to the picker, not six.
//
// Picker results are NSItemProviders pointing at PhotoKit's working
// copies; the actual byte work (re-encode, hash, thumbnail) lives in
// `AttachmentImporter`. This view's job is just to surface the picker
// and hand back the `result` array.
struct AttachmentPicker: UIViewControllerRepresentable {
    let onPicked: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        // .images ∪ .videos — anything else we don't have a handler for
        // yet. `preferredAssetRepresentationMode = .current` skips
        // PhotoKit's HEIC → JPEG transcode (we do our own downscale
        // pass and want the highest-fidelity input).
        config.filter = PHPickerFilter.any(of: [.images, .videos])
        config.selectionLimit = 6
        config.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: PHPickerViewController, context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([PHPickerResult]) -> Void

        init(onPicked: @escaping ([PHPickerResult]) -> Void) {
            self.onPicked = onPicked
        }

        func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            // Hand the results back as-is; the caller decides when to
            // dismiss the sheet. Empty results = user cancelled, but we
            // pass them through so the caller can still drop the sheet.
            onPicked(results)
        }
    }
}

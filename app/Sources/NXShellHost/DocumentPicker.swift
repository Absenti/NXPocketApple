import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// UIKit's document picker, for a file the shell reads itself (the .p12 exported from SideStore). SwiftUI's
/// `fileImporter` is not used here: with another `fileImporter` attached higher up (the game import, which accepts only
/// zips and folders) it showed the wrong types, and a .p12 could not be chosen. This one has its own types, and any
/// file can be picked: the shell checks what it got.
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.item]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // A copy, so the file can be read without a security scope.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) } else { parent.onCancel() }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.onCancel() }
    }
}

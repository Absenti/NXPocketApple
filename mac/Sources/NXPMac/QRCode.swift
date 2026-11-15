import AppKit
import CoreImage
import SwiftUI

/// A QR code for a link, drawn crisp at any size: the generator's modules are enlarged without smoothing.
struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .accessibilityLabel("QR code to scan with the iPhone's camera")
        }
    }

    static func image(for text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        // "M" survives a glare or a smudge on the screen without making the code denser than it needs to be.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

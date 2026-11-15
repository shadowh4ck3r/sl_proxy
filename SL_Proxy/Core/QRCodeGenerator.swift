import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Renders a string as a QR code (used by the Proxy Share QR sheet).
enum QRCodeGenerator {
    private static let context = CIContext()

    /// Crisp QR image for `text`; `scale` multiplies the module size so the bitmap stays sharp when
    /// SwiftUI scales it. Nil only when CoreImage refuses the payload (far above 2 KB).
    static func image(for text: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

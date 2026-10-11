// SPDX-License-Identifier: AGPL-3.0-only

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#else
import AppKit
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#endif

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// A QR code drawn with Core Image: dark modules on a starlight card, which
/// every scanner reads (inverted codes aren't universally supported).
struct QRCodeView: View {
    let payload: String

    var body: some View {
        Group {
            if let image = Self.render(payload) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode").resizable().scaledToFit()
            }
        }
        .foregroundStyle(.black)
        .padding(14)
        .background(Palette.starlight, in: .rect(cornerRadius: 22))
        .accessibilityLabel("QR code")
    }

    static func render(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let qr = filter.outputImage else { return nil }
        let scaled = qr.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

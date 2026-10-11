// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

#if os(iOS)
import VisionKit

/// Live QR scanning with VisionKit's DataScannerViewController (on-device).
struct CodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                if case .barcode(let code) = item, let value = code.payloadStringValue, !delivered {
                    delivered = true
                    onCode(value)
                }
            }
        }
    }
}
#else
struct CodeScanner: View {
    let onCode: (String) -> Void
    static var isAvailable: Bool { false }
    var body: some View { EmptyView() }
}
#endif

/// Camera scanning where available, plus paste for Macs, Simulators and links.
struct ScanOrPaste: View {
    let prompt: String
    let onCode: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(spacing: 16) {
            if CodeScanner.isAvailable {
                CodeScanner(onCode: onCode)
                    .clipShape(.rect(cornerRadius: 24))
                    .frame(maxHeight: 420)
            } else {
                ContentUnavailableView("No camera scanner here", systemImage: "camera.metering.unknown",
                                       description: Text("Paste the code or link instead."))
                    .frame(maxHeight: 220)
            }
            HStack {
                TextField(prompt, text: $text)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .writingToolsBehavior(.disabled)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !text.isEmpty { onCode(text) } }
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { onCode(s) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
            }
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

/// Six groups of five digits, a QR code that either phone can scan, and the
/// four-word check phrase for confirming out loud (PROTOCOL.md 3.6).
struct SafetyNumberView: View {
    let contact: Address

    @Environment(AppModel.self) private var model
    @State private var number: SafetyNumber?
    @State private var verified = false
    @State private var scanning = false
    @State private var scanResult: Bool?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let number {
                    QRCodeView(payload: number.qrPayload)
                        .frame(maxWidth: 220)
                    Grid(horizontalSpacing: 22, verticalSpacing: 10) {
                        GridRow { ForEach(0..<3, id: \.self) { Text(number.groups[$0]) } }
                        GridRow { ForEach(3..<6, id: \.self) { Text(number.groups[$0]) } }
                    }
                    .font(.title2.monospacedDigit().weight(.medium))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Safety number \(number.groups.joined(separator: " "))")

                    VStack(spacing: 6) {
                        Text("Check phrase").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(number.checkPhrase.joined(separator: " · "))
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .khensuGlass(in: .rect(cornerRadius: 18))

                    Text("Compare these numbers with your contact in person, or scan the code on their screen. If they match, nobody is intercepting your messages.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let scanResult {
                        Label(scanResult ? "Numbers match" : "Numbers don't match", systemImage: scanResult ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .foregroundStyle(scanResult ? Palette.starlight : .red)
                            .font(.headline)
                    }

                    GlassEffectContainer {
                        HStack {
                            Button(scanning ? "Stop Scanning" : "Scan Their Code", systemImage: "qrcode.viewfinder") { scanning.toggle() }
                                .buttonStyle(.glass)
                            Button(verified ? "Verified" : "Mark as Verified", systemImage: verified ? "checkmark.seal.fill" : "checkmark.seal") {
                                setVerified(!verified)
                            }
                            .buttonStyle(.glassProminent)
                            .foregroundStyle(.black)
                        }
                    }
                    if scanning {
                        ScanOrPaste(prompt: "khensu-verify:…") { code in
                            scanning = false
                            scanResult = code == number.qrPayload
                            if scanResult == true { setVerified(true) }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .padding()
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Safety Number")
        .task {
            number = try? await model.core.safetyNumber(with: contact)
            verified = await model.core.contact(contact)?.verified ?? false
        }
    }

    private func setVerified(_ on: Bool) {
        verified = on
        Task {
            try? await model.core.setVerified(on, contact: contact)
            await model.refresh()
        }
    }
}

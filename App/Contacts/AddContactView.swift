// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

struct AddContactView: View {
    let onAdded: (Conversation) -> Void

    enum Mode: String, CaseIterable { case myCode = "My Code", scan = "Scan" }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .myCode
    @State private var pending: ContactInvite?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                switch mode {
                case .myCode:
                    MyCodeCard()
                case .scan:
                    ScanOrPaste(prompt: "khensu.nu/c/… link") { handle($0) }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.footnote)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Add Contact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .confirmationDialog("Add \(pending?.displayName ?? "")?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("Add and Start Chat") { add() }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                if let p = pending {
                    Text("\(p.handle?.domain ?? p.address.short)\nCompare safety numbers in person to verify.")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    private func handle(_ code: String) {
        do {
            pending = try ContactInvite(parsing: code)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() {
        guard let invite = pending else { return }
        pending = nil
        Task {
            do {
                onAdded(try await model.addContact(invite))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Your own contact code: QR, name, handle and address.
struct MyCodeCard: View {
    @Environment(AppModel.self) private var model
    @State private var invite: ContactInvite?

    var body: some View {
        VStack(spacing: 14) {
            if let invite {
                QRCodeView(payload: invite.url.absoluteString)
                    .frame(maxWidth: 280)
                Text(invite.displayName).font(.title2.weight(.semibold))
                if let h = invite.handle {
                    HandleLabel(handle: h)
                }
                Text(invite.address.bech32m)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                ShareLink(item: invite.url) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
            } else {
                ProgressView()
            }
        }
        .task { invite = try? await model.core.myInvite() }
    }
}

struct HandleLabel: View {
    let handle: Handle
    var body: some View {
        HStack(spacing: 6) {
            Text(handle.domain)
            if handle.status == .pending {
                Text("pending")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .khensuGlass(in: .capsule)
                    .accessibilityLabel("Handle pending: registration opens with key transparency")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

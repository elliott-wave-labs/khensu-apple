// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

struct ChatInfoView: View {
    let conversation: Conversation

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var contact: Contact?
    @State private var path: [Address] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(spacing: 10) {
                        Avatar(title: conversation.title, size: 88, kind: conversation.avatarKind)
                        HStack(spacing: 6) {
                            Text(conversation.title).font(.title2.weight(.semibold))
                            if conversation.isVerified { Image(systemName: "checkmark.seal.fill") }
                        }
                        if let h = contact?.handle { HandleLabel(handle: h) }
                        if let a = contact?.address {
                            Text(a.bech32m).font(.caption2.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                if conversation.kind == .direct, let address = conversation.members.first {
                    Section {
                        NavigationLink(value: address) {
                            Label("Safety Number", systemImage: "checkmark.shield")
                        }
                    } header: {
                        Text("Encryption")
                    } footer: {
                        Text("ML-KEM-1024 and ML-DSA-87 (MLS). A new key for every message; device keys rotate at least every 5 minutes.")
                    }
                }

                Section("Chat") {
                    LabeledContent {
                        Text(conversation.disappearingAfter == 0 ? "Off" : Duration.seconds(Int(conversation.disappearingAfter)).formatted(.units(allowed: [.days, .hours], width: .wide)))
                    } label: {
                        Label("Disappearing Messages", systemImage: "moonphase.waning.crescent")
                    }
                    Toggle(isOn: Binding(get: { conversation.isMuted }, set: { model.apply(.mute($0), to: conversation.id) })) {
                        Label("Mute", systemImage: "bell.slash")
                    }
                    Toggle(isOn: Binding(get: { conversation.isPinned }, set: { model.apply(.pin($0), to: conversation.id) })) {
                        Label("Pin", systemImage: "pin")
                    }
                }

                if conversation.kind == .group {
                    Section("\(conversation.members.count + 1) Members") {
                        Label("You", systemImage: "person.crop.circle")
                        ForEach(conversation.members, id: \.self) { m in
                            Label(m.short, systemImage: "person.crop.circle").font(.body.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: Address.self) { SafetyNumberView(contact: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task {
                if let a = conversation.members.first, conversation.kind == .direct {
                    contact = await model.core.contact(a)
                    if model.launch.screen == .safety { path = [a] }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }
}

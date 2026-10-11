// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

/// On-device search over decrypted messages (PLAN.md, "Local search and memory").
/// v0.1 runs a plain match in the core; the KhensuMemory index and "Ask khensu"
/// (Foundation Models, on-device only) come later.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [Message] = []

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "sparkle.magnifyingglass").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Ask khensu").font(.headline)
                                Text("Questions about your chats, answered on this device with citations. Nothing is sent to a server.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    } footer: {
                        Text("Search runs on your device over your encrypted history.")
                    }
                    Section("Chats") {
                        ForEach(model.conversations.prefix(6)) { c in
                            Button {
                                open(c.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Avatar(title: c.title, size: 36, kind: c.avatarKind)
                                    Text(c.title).foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    Section("Messages") {
                        ForEach(results) { m in
                            Button {
                                open(m.conversationID)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(model.conversation(m.conversationID)?.title ?? "").font(.headline)
                                        Spacer()
                                        Text(m.sentAt.chatTimestamp).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(m.body.previewText).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Messages, chats, people")
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(150))
                results = (try? await model.core.search(query)) ?? []
            }
        }
    }

    private func open(_ id: ConversationID) {
        model.selectedConversation = id
        model.selectedTab = .chats
    }
}

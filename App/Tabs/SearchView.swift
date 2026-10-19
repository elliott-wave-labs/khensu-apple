// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

/// On-device search over decrypted messages (PLAN.md, "Local search and memory"),
/// and Ask khėnsu: questions answered by the on-device model from what search
/// finds. Plain search runs a match in the core; the KhensuMemory index comes later.
struct SearchView: View {
    enum Mode: Hashable { case messages, ask }

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var mode = Mode.messages
    @State private var results: [Message] = []
    @State private var ask = AskKhensu()

    var body: some View {
        NavigationStack {
            List {
                switch mode {
                case .messages: messages
                case .ask: askContent
                }
            }
            .navigationTitle(mode == .ask ? "Ask khėnsu" : "Search")
            .appNavChrome()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: mode == .ask ? "Ask about your chats, or ~summarize" : "Messages, chats, people")
            .searchScopes($mode) {
                Text("Messages").tag(Mode.messages)
                Text("Ask khėnsu").tag(Mode.ask)
            }
            .onSubmit(of: .search) {
                if mode == .ask { ask.run(query, app: model) }
            }
            .onChange(of: query) { _, q in
                if q.hasPrefix("~") { mode = .ask }
                if q.isEmpty { ask.reset() }
            }
            .onChange(of: mode) { _, _ in ask.reset() }
            .task(id: query) {
                guard mode == .messages, !query.hasPrefix("~") else { return }
                try? await Task.sleep(for: .milliseconds(150))
                results = (try? await model.core.search(query)) ?? []
            }
        }
    }

    // MARK: Messages

    @ViewBuilder private var messages: some View {
        if query.isEmpty {
            Section {
                Button { mode = .ask } label: { askIntro }
                    .foregroundStyle(.primary)
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

    private var askIntro: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass").font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask khėnsu").font(.headline)
                Text("Questions about your chats, answered on this device with citations. Nothing is sent to a server.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Ask khėnsu

    @ViewBuilder private var askContent: some View {
        if ask.phase == .idle {
            Section {
                askIntro
                if let reason = ask.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Commands") {
                ForEach(AskCommand.commands, id: \.name) { c in
                    Button {
                        query = c.name.hasSuffix(">") ? "~find " : c.name
                        if !c.name.hasSuffix(">") { ask.run(query, app: model) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.body.monospaced())
                            Text(c.text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            privacyFooter
        } else {
            Section(ask.heading) {
                switch ask.phase {
                case .searching:
                    ProgressView("Looking through your chats")
                case .answering where ask.answer.isEmpty:
                    ProgressView("Thinking on this device")
                case .failed(let why):
                    Label(why, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                default:
                    Text(ask.answer).textSelection(.enabled)
                }
            }
            if !ask.sources.isEmpty {
                Section("From your chats") {
                    ForEach(ask.sources) { s in
                        Button {
                            if let id = s.conversationID { open(id) } else { model.selectedTab = .feed }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(s.place).font(.headline)
                                    Spacer()
                                    Text(s.date.chatTimestamp).font(.caption).foregroundStyle(.secondary)
                                }
                                Text("\(s.sender): \(s.text)").foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            privacyFooter
        }
    }

    private var privacyFooter: some View {
        Section {} footer: {
            Label("Answered by the model on this device. Nothing leaves it.", systemImage: "lock.fill")
                .font(.footnote)
        }
    }

    private func open(_ id: ConversationID) {
        model.selectedConversation = id
        model.selectedTab = .chats
    }
}

// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit
import SwiftUI

enum ChatFolder: String, CaseIterable, Identifiable {
    case all = "All", personal = "Personal", groups = "Groups", channels = "Channels", unread = "Unread"
    var id: String { rawValue }

    func includes(_ c: Conversation) -> Bool {
        switch self {
        case .all: true
        case .personal: c.kind == .direct || c.kind == .notes
        case .groups: c.kind == .group
        case .channels: c.kind == .channel
        case .unread: c.unreadCount > 0
        }
    }
}

/// Chat list and conversation: a stack on iPhone, columns on iPad and Mac.
struct ChatsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ChatListView(selection: $model.selectedConversation)
        } detail: {
            if let id = model.selectedConversation, model.conversation(id) != nil {
                ConversationView(conversationID: id)
                    .id(id)
            } else {
                EmptyDetail()
            }
        }
    }
}

private struct EmptyDetail: View {
    var body: some View {
        ZStack {
            DotNetwork(count: 70, opacity: 0.35).frame(maxWidth: 420, maxHeight: 420)
            ContentUnavailableView("Choose a chat", systemImage: "bubble.left.and.bubble.right", description: Text("Messages are end-to-end encrypted and travel through the mixnet."))
        }
    }
}

struct ChatListView: View {
    @Binding var selection: ConversationID?
    @Environment(AppModel.self) private var model
    @State private var folder: ChatFolder = .all
    @State private var showArchived = false
    @State private var showAddContact = false
    @State private var showSharePicker = false

    private var visible: [Conversation] {
        model.conversations.filter { $0.isArchived == showArchived && folder.includes($0) }
    }

    private var archivedCount: Int { model.conversations.filter(\.isArchived).count }

    var body: some View {
        List(selection: $selection) {
            if !model.sharedDrafts.isEmpty && !showArchived {
                Section {
                    Button {
                        showSharePicker = true
                    } label: {
                        Label("\(model.sharedDrafts.count) shared item\(model.sharedDrafts.count == 1 ? "" : "s") waiting. Choose a chat", systemImage: "square.and.arrow.down")
                    }
                }
            }
            if !showArchived && archivedCount > 0 && folder == .all {
                Button {
                    withAnimation { showArchived = true }
                } label: {
                    Label("Archived Chats (\(archivedCount))", systemImage: "archivebox")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(visible) { c in
                NavigationLink(value: c.id) {
                    ChatRow(conversation: c)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        model.apply(c.unreadCount > 0 ? .markRead : .markUnread, to: c.id)
                    } label: {
                        Label(c.unreadCount > 0 ? "Read" : "Unread", systemImage: c.unreadCount > 0 ? "checkmark.message" : "message.badge")
                    }
                    .tint(Color(white: 0.42))
                    Button {
                        model.apply(.pin(!c.isPinned), to: c.id)
                    } label: {
                        Label(c.isPinned ? "Unpin" : "Pin", systemImage: c.isPinned ? "pin.slash" : "pin")
                    }
                    .tint(Color(white: 0.28))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        model.apply(.archive(!c.isArchived), to: c.id)
                    } label: {
                        Label(c.isArchived ? "Unarchive" : "Archive", systemImage: c.isArchived ? "tray.and.arrow.up" : "archivebox")
                    }
                    .tint(Color(white: 0.34))
                    Button {
                        model.apply(.mute(!c.isMuted), to: c.id)
                    } label: {
                        Label(c.isMuted ? "Unmute" : "Mute", systemImage: c.isMuted ? "bell" : "bell.slash")
                    }
                    .tint(Color(white: 0.22))
                }
                .contextMenu {
                    Button(c.isPinned ? "Unpin" : "Pin", systemImage: c.isPinned ? "pin.slash" : "pin") { model.apply(.pin(!c.isPinned), to: c.id) }
                    Button(c.isMuted ? "Unmute" : "Mute", systemImage: c.isMuted ? "bell" : "bell.slash") { model.apply(.mute(!c.isMuted), to: c.id) }
                    Button(c.unreadCount > 0 ? "Mark as Read" : "Mark as Unread", systemImage: "checkmark.message") {
                        model.apply(c.unreadCount > 0 ? .markRead : .markUnread, to: c.id)
                    }
                    Button(c.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox") { model.apply(.archive(!c.isArchived), to: c.id) }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView(showArchived ? "No archived chats" : "No chats here", systemImage: folder == .unread ? "checkmark.message" : "bubble.left.and.bubble.right",
                                       description: Text(showArchived ? "Swipe left on a chat to archive it." : "Add a contact with their QR code to start."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !showArchived { FolderBar(folder: $folder, unread: model.conversations) }
        }
        .navigationTitle(showArchived ? "Archived" : "Chats")
        .toolbar {
            if showArchived {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", systemImage: "chevron.backward") { withAnimation { showArchived = false } }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Add Contact", systemImage: "qrcode.viewfinder") { showAddContact = true }
                    Button("New Group", systemImage: "person.3") {}.disabled(true)
                    Button("New Channel", systemImage: "megaphone") {}.disabled(true)
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showAddContact) {
            AddContactView { conversation in
                showAddContact = false
                selection = conversation.id
            }
        }
        .sheet(isPresented: $showSharePicker) {
            ShareTargetPicker()
        }
        .onAppear {
            if model.launch.screen == .addContact { showAddContact = true }
            if model.launch.screen == .conversation || model.launch.screen == .safety, selection == nil {
                selection = model.conversations.first(where: { $0.kind == .direct })?.id
            }
        }
    }
}

/// Telegram-style folder tabs, built from stock glass buttons.
private struct FolderBar: View {
    @Binding var folder: ChatFolder
    let unread: [Conversation]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ChatFolder.allCases) { f in
                        let count = unread.filter { !$0.isArchived && !$0.isMuted && f.includes($0) }.map(\.unreadCount).reduce(0, +)
                        if f == folder {
                            Button { folder = f } label: { label(f, count) }
                                .buttonStyle(.glassProminent)
                                .foregroundStyle(.black)
                        } else {
                            Button { folder = f } label: { label(f, count) }
                                .buttonStyle(.glass)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folders")
    }

    private func label(_ f: ChatFolder, _ count: Int) -> some View {
        HStack(spacing: 6) {
            Text(f.rawValue)
            if count > 0 && f != .unread {
                Text("\(count)").font(.caption2.weight(.bold)).monospacedDigit().opacity(0.7)
            }
        }
        .font(.subheadline.weight(.semibold))
    }
}

struct ChatRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            Avatar(title: conversation.title, size: 52, kind: conversation.avatarKind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(conversation.title).font(.headline).lineLimit(1)
                    if conversation.isVerified {
                        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Palette.starlight)
                            .accessibilityLabel("Verified")
                    }
                    if conversation.isMuted {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Muted")
                    }
                    if conversation.disappearingAfter > 0 {
                        Image(systemName: "moonphase.waning.crescent").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Disappearing messages on")
                    }
                    Spacer(minLength: 4)
                    if let last = conversation.lastMessage {
                        if last.isMine { DeliveryTicks(state: last.state).font(.caption2) }
                        Text(last.sentAt.chatTimestamp).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    Text(conversation.lastMessage?.body.previewText ?? "No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(.black)
                            .background(conversation.isMuted ? Palette.dim : Palette.starlight, in: .capsule)
                            .accessibilityLabel("\(conversation.unreadCount) unread")
                    } else if conversation.isPinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).rotationEffect(.degrees(45))
                            .accessibilityLabel("Pinned")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DeliveryTicks: View {
    let state: DeliveryState
    var body: some View {
        Group {
            switch state {
            case .queued: Image(systemName: "clock")
            case .sending: Image(systemName: "arrow.up.circle")
            case .sent: Image(systemName: "checkmark")
            case .delivered: Image(systemName: "checkmark.circle")
            case .read: Image(systemName: "checkmark.circle.fill")
            case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel(state.rawValue.capitalized)
    }
}

extension Conversation {
    var avatarKind: Avatar.Kind {
        switch kind {
        case .direct: .person
        case .group: .group
        case .channel: .channel
        case .notes: .notes
        }
    }
}

extension Date {
    var chatTimestamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return String(localized: "Yesterday") }
        if let days = cal.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Picks the chat for items handed over by the Share Extension.
private struct ShareTargetPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.sharedDrafts, id: \.self) { Text($0).lineLimit(3).foregroundStyle(.secondary) }
                }
                Section("Send to") {
                    ForEach(model.conversations.filter { !$0.isArchived && $0.kind != .channel }) { c in
                        Button {
                            Task {
                                await model.sendSharedDrafts(to: c.id)
                                model.selectedConversation = c.id
                                dismiss()
                            }
                        } label: {
                            HStack { Avatar(title: c.title, size: 32, kind: c.avatarKind); Text(c.title) }
                        }
                    }
                }
            }
            .navigationTitle("Shared items")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Discard", role: .destructive) {
                        model.discardSharedDrafts()
                        dismiss()
                    }
                }
            }
        }
    }
}

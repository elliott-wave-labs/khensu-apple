// SPDX-License-Identifier: AGPL-3.0-only

import ImageIO
import KhensuKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationView: View {
    let conversationID: ConversationID

    @Environment(AppModel.self) private var model
    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var photo: PhotosPickerItem?
    @State private var showInfo = false
    @FocusState private var composerFocused: Bool

    private var conversation: Conversation? { model.conversation(conversationID) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    EncryptionNotice(conversation: conversation)
                        .padding(.vertical, 12)
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        if i == 0 || !Calendar.current.isDate(messages[i - 1].sentAt, inSameDayAs: m.sentAt) {
                            DaySeparator(date: m.sentAt)
                        }
                        MessageBubble(message: m, senderName: senderName(m))
                            .id(m.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if conversation?.kind == .channel {
                Text("Only admins can post in this channel.")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            } else {
                composer
            }
        }
        .navigationTitle(conversation?.title ?? "")
        .navigationSubtitle(subtitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if conversation?.kind == .direct {
                    Button("Video call", systemImage: "video") { Task { await call(.call) } }
                }
                Button("Info", systemImage: "info.circle") { showInfo = true }
            }
        }
        .sheet(isPresented: $showInfo) {
            if let conversation { ChatInfoView(conversation: conversation) }
        }
        .task(id: conversation?.lastMessage) { await load() }
        .task {
            if (conversation?.unreadCount ?? 0) > 0 { model.apply(.markRead, to: conversationID) }
            if model.launch.screen == .safety { showInfo = true }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await attach(item) }
        }
    }

    private var subtitle: String {
        guard let c = conversation else { return "" }
        switch c.kind {
        case .direct: return c.isVerified ? "verified · end-to-end encrypted" : "end-to-end encrypted"
        case .group: return "\(c.members.count + 1) members"
        case .channel: return "channel"
        case .notes: return "only on your devices"
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) {
                Image(systemName: "plus")
                    .font(.title3.weight(.medium))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Attach photo")

            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .writingToolsBehavior(.disabled)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .khensuGlass(in: .rect(cornerRadius: 20))
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .foregroundStyle(.black)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Hosts the call, then sends its room ID through this encrypted chat.
    private func call(_ mode: CallSession.Mode) async {
        do {
            let session = try CallSession(hosting: mode, name: model.callName)
            model.activeCall = session
            await model.send(.text(CallInvite.text(room: session.roomID, mode: mode)), to: conversationID)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func senderName(_ m: Message) -> String? {
        guard conversation?.kind == .group, case .contact(let a) = m.sender else { return nil }
        return a.short
    }

    private func load() async {
        if let m = try? await model.core.messages(in: conversationID) { messages = m }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            await model.send(.text(text), to: conversationID)
            await load()
        }
    }

    /// v0.1 placeholder: records the photo's size and a tiny preview. Encoding
    /// with nu-media and the chunked upload over the bulk lane come later.
    private func attach(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let ref = AttachmentRef.image(from: data)
        let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        await model.send(OutgoingMessage(body: .attachment(ref, caption: caption.isEmpty ? nil : caption)), to: conversationID)
        await load()
    }
}

/// An invitation to a call or a live room, sent through the encrypted chat.
private struct CallInviteCard: View {
    let mode: CallSession.Mode
    let room: String
    let mine: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mode == .live ? "dot.radiowaves.left.and.right" : "video.fill")
                .font(.title3)
                .foregroundStyle(LinearGradient(colors: Aura.core, startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .live ? "Live room" : "Video call").fontWeight(.semibold)
                Text(mine ? "You invited them" : "End to end encrypted").font(.caption).foregroundStyle(.secondary)
            }
            if !mine {
                Spacer(minLength: 12)
                Button(mode == .live ? "Watch" : "Join") {
                    model.activeCall = CallSession(joining: room, mode: mode, name: model.callName)
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(.black)
            }
        }
    }
}

extension AttachmentRef {
    static func image(from data: Data) -> AttachmentRef {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return AttachmentRef(kind: .image, byteCount: data.count) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 48,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
        var preview: Data?
        if let thumb {
            let out = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
                if CGImageDestinationFinalize(dest) { preview = out as Data }
            }
        }
        return AttachmentRef(kind: .image, byteCount: data.count,
                             pixelWidth: props?[kCGImagePropertyPixelWidth] as? Int,
                             pixelHeight: props?[kCGImagePropertyPixelHeight] as? Int,
                             preview: preview)
    }
}

private struct EncryptionNotice: View {
    let conversation: Conversation?
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.caption)
            Text("Messages are end-to-end encrypted with post-quantum keys and cross the mixnet, so nobody, not even the nodes, can see what you say or who you talk to.")
                .font(.caption)
                .multilineTextAlignment(.center)
            if let c = conversation, c.disappearingAfter > 0 {
                Label("Messages disappear after \(Duration.seconds(Int(c.disappearingAfter)).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide)))", systemImage: "moonphase.waning.crescent")
                    .font(.caption.weight(.medium))
            }
        }
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: 420)
        .khensuGlass(in: .rect(cornerRadius: 16))
    }
}

private struct DaySeparator: View {
    let date: Date
    var body: some View {
        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .khensuGlass(in: .capsule)
            .padding(.vertical, 6)
    }
}

struct MessageBubble: View {
    let message: Message
    var senderName: String?

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                if let senderName {
                    Text(senderName).font(.caption.weight(.semibold)).foregroundStyle(Palette.silver)
                }
                content
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(message.sentAt.formatted(date: .omitted, time: .shortened))
                    if message.isMine { DeliveryTicks(state: message.state) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .khensuGlass(tint: message.isMine ? Palette.silver.opacity(0.32) : nil, in: .rect(cornerRadius: 18))
            .contextMenu {
                if case .text(let t) = message.body {
                    Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(t) }
                }
                Button("Reply", systemImage: "arrowshape.turn.up.left") {}.disabled(true)
                Button("Edit", systemImage: "pencil") {}.disabled(true)
            }
            if !message.isMine { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch message.body {
        case .text(let t):
            if let (mode, room) = CallInvite.parse(t) {
                CallInviteCard(mode: mode, room: room, mine: message.isMine)
            } else {
                Text(t).textSelection(.enabled)
            }
        case .attachment(let a, let caption):
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let p = a.preview, let image = PlatformImage(data: p) {
                        Image(platformImage: image).resizable().scaledToFill().blur(radius: 6)
                    } else {
                        Palette.graphiteRaised
                    }
                    VStack(spacing: 4) {
                        Image(systemName: "photo").font(.title2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(a.byteCount), countStyle: .file)).font(.caption)
                    }
                    .foregroundStyle(Palette.starlight)
                }
                .frame(width: 220, height: a.aspectHeight(forWidth: 220))
                .clipShape(.rect(cornerRadius: 12))
                Text("Photo placeholder: nu-media encoding and upload arrive in a later version.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let caption { Text(caption) }
            }
        }
    }
}

extension AttachmentRef {
    func aspectHeight(forWidth w: CGFloat) -> CGFloat {
        guard let pw = pixelWidth, let ph = pixelHeight, pw > 0 else { return w * 0.75 }
        return min(max(w * CGFloat(ph) / CGFloat(pw), 120), 320)
    }
}

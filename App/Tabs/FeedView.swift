// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import KhensuKit
import SwiftUI

/// The public feed: full-screen videos, one per page, swiped vertically
/// (PLAN.md, "Public square"). The server comes from `KhensuFeedAPI`; with none
/// set the tab says the feed is offline and shows nothing else.
struct FeedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var feed = FeedModel()
    @State private var players = FeedPlayers()
    @State private var visibleID: String?
    @State private var composing = false
    @State private var reporting: FeedPost?
    @State private var notice: String?

    static let reportReasons = ["Spam", "Harassment or hate", "Violence", "Sexual content", "Illegal", "Something else"]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Feed")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                #endif
                .toolbar {
                    if feed.isConfigured {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Post", systemImage: "plus") { composing = true }
                        }
                    }
                }
        }
        .task { await feed.start() }
        .onAppear { players.resume() }
        .onDisappear { players.pauseAll() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { players.resume() } else { players.pauseAll() }
        }
        .onChange(of: feed.isMuted) { _, muted in players.isMuted = muted }
        .onChange(of: feed.posts) { _, posts in
            if visibleID == nil || !posts.contains(where: { $0.id == visibleID }) { visibleID = posts.first?.id }
            players.show(visibleID, in: posts)
        }
        .onChange(of: visibleID) { _, id in
            players.show(id, in: feed.posts)
            if let post = feed.posts.first(where: { $0.id == id }) { Task { await feed.didShow(post) } }
        }
        .sheet(isPresented: $composing, onDismiss: players.resume) {
            FeedComposeView(feed: feed, defaultHandle: model.identity?.handle?.name ?? "")
                .onAppear { players.pauseAll() }
        }
        .confirmationDialog("Report this post", isPresented: Binding(get: { reporting != nil }, set: { if !$0 { reporting = nil } }),
                            titleVisibility: .visible, presenting: reporting) { post in
            ForEach(Self.reportReasons, id: \.self) { reason in
                Button(reason) { report(post, reason: reason) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The people who run the feed review every report.")
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder private var content: some View {
        switch feed.phase {
        case .offline:
            unavailable("The public feed is offline", systemImage: "antenna.radiowaves.left.and.right.slash",
                        text: feed.isConfigured ? "It can't be reached right now." : "No feed server is set on this device.")
        case .failed(let why):
            unavailable("The feed didn't load", systemImage: "exclamationmark.triangle", text: why)
        case .loading where feed.posts.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if feed.posts.isEmpty {
                unavailable("No posts yet", systemImage: "play.rectangle.on.rectangle", text: "Be the first to post a video.")
            } else {
                pages
            }
        }
    }

    private func unavailable(_ title: String, systemImage: String, text: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(text)
        } actions: {
            if feed.isConfigured || title != "The public feed is offline" {
                Button("Try again") { Task { await feed.refresh() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pages: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(feed.posts) { post in
                        FeedPageView(post: post, player: players.players[post.id], isMuted: feed.isMuted, insets: geo.safeAreaInsets,
                                     toggleMute: { feed.isMuted.toggle() }, report: { reporting = post })
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(post.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleID)
            .scrollIndicators(.hidden)
            .refreshable { await feed.refresh() }
            .overlay(alignment: .bottom) {
                if feed.isLoadingMore {
                    ProgressView().padding(.bottom, geo.safeAreaInsets.bottom + 8)
                }
            }
            .ignoresSafeArea()
        }
        .background(.black)
    }

    private func report(_ post: FeedPost, reason: String) {
        Task {
            do {
                try await feed.report(post, reason: reason)
                notice = "Thanks. The post is hidden for you while it's reviewed."
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}

/// One full-screen post: the poster until its player is ready, then the looping video.
private struct FeedPageView: View {
    let post: FeedPost
    let player: AVQueuePlayer?
    let isMuted: Bool
    let insets: EdgeInsets
    let toggleMute: () -> Void
    let report: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            AsyncImage(url: post.posterURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.black
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            if let player {
                PlayerLayerView(player: player, gravity: post.aspectRatio < 0.8 ? .resizeAspectFill : .resizeAspect)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("@\(post.handle)").font(.headline)
                    if !post.caption.isEmpty {
                        Text(post.caption).font(.subheadline).lineLimit(4)
                    }
                    Text(post.createdAt, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .shadow(radius: 4)
                Spacer(minLength: 0)
                VStack(spacing: 14) {
                    Button(isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", action: toggleMute)
                    Menu("More", systemImage: "ellipsis") {
                        Button("Report", systemImage: "flag", role: .destructive, action: report)
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, insets.bottom + 12)
        }
        .contentShape(.rect)
        .onTapGesture(perform: toggleMute)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video by @\(post.handle). \(post.caption)")
        .accessibilityAction(named: isMuted ? "Unmute" : "Mute", toggleMute)
    }
}

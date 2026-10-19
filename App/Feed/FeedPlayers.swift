// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import KhensuKit
import SwiftUI

/// One looping player per page near the screen: the visible post plays, the
/// next one is buffered so swiping is instant, everything further away is let go.
@MainActor @Observable
final class FeedPlayers {
    private struct Entry {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
    }

    @ObservationIgnored private var entries: [String: Entry] = [:] {
        didSet { players = entries.mapValues(\.player) }
    }
    /// The players pages draw; a page without one shows its poster.
    private(set) var players: [String: AVQueuePlayer] = [:]
    @ObservationIgnored private(set) var current: String?

    var isMuted = true {
        didSet { entries.values.forEach { $0.player.isMuted = isMuted } }
    }

    private func player(for post: FeedPost) -> AVQueuePlayer {
        if let entry = entries[post.id] { return entry.player }
        let item = AVPlayerItem(url: post.videoURL)
        item.preferredForwardBufferDuration = 4
        let player = AVQueuePlayer()
        player.isMuted = isMuted
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        let looper = AVPlayerLooper(player: player, templateItem: item)
        entries[post.id] = Entry(player: player, looper: looper)
        return player
    }

    /// Plays `id`, pauses the rest, preloads the following post and drops far-away players.
    func show(_ id: String?, in posts: [FeedPost]) {
        current = id
        guard let id, let i = posts.firstIndex(where: { $0.id == id }) else {
            pauseAll()
            return
        }
        let keep = Set(posts[max(0, i - 1)...min(posts.count - 1, i + 1)].map(\.id))
        for (key, entry) in entries where !keep.contains(key) {
            entry.player.pause()
            entry.player.removeAllItems()
            entries[key] = nil
        }
        for post in posts[i...min(posts.count - 1, i + 1)] {
            let player = player(for: post)
            if post.id == id { player.play() } else { player.pause() }
        }
        if i > 0 { entries[posts[i - 1].id]?.player.pause() }
    }

    func pauseAll() {
        entries.values.forEach { $0.player.pause() }
    }

    func resume() {
        guard let current else { return }
        entries[current]?.player.play()
    }

    func togglePlay() {
        guard let current, let player = entries[current]?.player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func releaseAll() {
        entries.values.forEach { $0.player.pause(); $0.player.removeAllItems() }
        entries = [:]
    }
}

/// An `AVPlayerLayer` filling its frame, without system playback controls.
struct PlayerLayerView: View {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    var body: some View {
        Representable(player: player, gravity: gravity)
            .accessibilityHidden(true)
    }

    #if os(iOS)
    private final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    private struct Representable: UIViewRepresentable {
        let player: AVPlayer
        let gravity: AVLayerVideoGravity

        func makeUIView(context: Context) -> LayerView {
            let view = LayerView()
            view.playerLayer.player = player
            view.playerLayer.videoGravity = gravity
            return view
        }

        func updateUIView(_ view: LayerView, context: Context) {
            if view.playerLayer.player !== player { view.playerLayer.player = player }
            view.playerLayer.videoGravity = gravity
        }
    }
    #else
    private final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    private struct Representable: NSViewRepresentable {
        let player: AVPlayer
        let gravity: AVLayerVideoGravity

        func makeNSView(context: Context) -> LayerView {
            let view = LayerView()
            view.playerLayer.player = player
            view.playerLayer.videoGravity = gravity
            return view
        }

        func updateNSView(_ view: LayerView, context: Context) {
            if view.playerLayer.player !== player { view.playerLayer.player = player }
            view.playerLayer.videoGravity = gravity
        }
    }
    #endif
}

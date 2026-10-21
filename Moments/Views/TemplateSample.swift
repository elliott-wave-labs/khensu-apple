// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import SwiftUI

/// A template's sample reel, rendered by this app's own renderer and bundled. Loops silently while the card is on screen;
/// with Reduce Motion it stays on the poster frame.
struct TemplateSample: View {
    let id: String
    var fill = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        ZStack {
            if let poster = Self.poster(id) {
                poster.resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            }
            if let player { PlayerLayerView(player: player, fill: fill) }
        }
        .allowsHitTesting(false)
        .onAppear { start() }
        .onDisappear { stop() }
        .accessibilityHidden(true)
    }

    private func start() {
        guard !reduceMotion, player == nil,
              let url = Bundle.main.url(forResource: "template-\(id)", withExtension: "mp4") else { return }
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
        player = p
        p.play()
    }

    private func stop() {
        player?.pause()
        looper = nil
        player = nil
    }

    static func poster(_ id: String) -> Image? {
        guard let path = Bundle.main.path(forResource: "template-\(id)", ofType: "jpg") else { return nil }
        #if os(iOS)
        return UIImage(contentsOfFile: path).map { Image(uiImage: $0) }
        #else
        return NSImage(contentsOfFile: path).map { Image(nsImage: $0) }
        #endif
    }
}

#if os(iOS)
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        v.playerLayer.player = player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}
#else
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer = AVPlayerLayer()
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let l = v.layer as? AVPlayerLayer else { return }
        l.player = player
        l.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}
#endif

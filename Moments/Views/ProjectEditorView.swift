// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import ImageIO
import SwiftUI

struct ProjectEditorView: View {
    @Environment(ProjectStore.self) private var store
    let project: MomentProject
    @State private var model: EditorModel?

    var body: some View {
        Group {
            if let model { EditorScreen(model: model) } else { Color.black.ignoresSafeArea() }
        }
        .onAppear { if model == nil { model = EditorModel(project: project, store: store) } }
    }
}

private struct EditorScreen: View {
    let model: EditorModel

    var body: some View {
        @Bindable var project = model.project
        VStack(spacing: 0) {
            EditorCanvas(model: model)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            Transport(model: model)
                .padding(.horizontal, 14)
            TimelineStrip(model: model)
                .frame(height: 92)
            ToolBar(model: model)
            Divider().opacity(0.3)
            ScrollView {
                ToolPanel(model: model)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(project.title)
        .momentsNavChrome()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { model.store.save(project); model.status = "Saved on this device." }
            }
        }
        .overlay(alignment: .top) {
            if let busy = model.busy {
                HStack(spacing: 10) {
                    if let p = model.progress { ProgressView(value: p).frame(width: 90) } else { ProgressView() }
                    Text(busy).font(.caption.weight(.medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 8)
            } else if let status = model.status {
                Text(status).font(.caption).padding(.horizontal, 14).padding(.vertical, 9)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8)
                    .task(id: status) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if model.status == status { model.status = nil }
                    }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { model.shareItems != nil }, set: { if !$0 { model.shareItems = nil } })) {
            if let items = model.shareItems { ShareItemsSheet(items: items) }
        }
        .onDisappear { model.player.pause(); model.store.save(project) }
    }
}

// MARK: - Canvas

private struct EditorCanvas: View {
    let model: EditorModel
    @State private var dragStart: NormPoint?

    var body: some View {
        let size = model.project.format.size
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.07))
            if model.project.clips.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "plus.rectangle.on.rectangle").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Add photos and video, or record, to start.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                PlayerSurface(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture { model.togglePlay() }
                GeometryReader { geo in handle(in: geo.size) }
                if model.isBuilding {
                    ProgressView().controlSize(.small).padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .frame(maxHeight: 360)
    }

    /// Drag handle for the selected text, sticker or overlay (the frame itself is drawn by the renderer).
    @ViewBuilder
    private func handle(in size: CGSize) -> some View {
        if let i = model.overlayIndex, model.project.overlays[i].kind != .drawing, let pose = model.overlayPose(model.project.overlays[i].id) {
            let id = model.project.overlays[i].id
            Circle()
                .strokeBorder(.white, lineWidth: 2)
                .background(Circle().fill(.white.opacity(0.18)))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: model.project.overlays[i].keyframes?.isEmpty == false ? "diamond.fill" : "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 12, weight: .bold)))
                .position(x: pose.center.x * size.width, y: pose.center.y * size.height)
                .gesture(DragGesture()
                    .onChanged { g in
                        let start = dragStart ?? pose.center
                        if dragStart == nil { dragStart = start; model.player.pause() }
                        model.editOverlayPose(id, live: true) {
                            $0.center = NormPoint(x: min(1.2, max(-0.2, start.x + g.translation.width / size.width)),
                                                  y: min(1.2, max(-0.2, start.y + g.translation.height / size.height)))
                        }
                    }
                    .onEnded { _ in dragStart = nil; model.commit() })
        }
    }
}

#if os(iOS)
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> Surface {
        let v = Surface()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ v: Surface, context: Context) { v.playerLayer.player = player }
}
#else
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { (v.layer as? AVPlayerLayer)?.player = player }
}
#endif

// MARK: - Transport

private struct Transport: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { min(model.time, max(0.001, model.duration)) }, set: { model.player.pause(); model.seek($0) }),
                   in: 0...max(0.001, model.duration))
                .disabled(model.project.clips.isEmpty)
            HStack(spacing: 14) {
                Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }
                Text("\(stamp(model.time)) / \(stamp(model.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors").labelStyle(.titleAndIcon) }
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(model.project.clips.isEmpty)
        }
        .padding(.vertical, 6)
    }

    private func stamp(_ t: Double) -> String {
        let frames = Int((t.truncatingRemainder(dividingBy: 1)) * Double(model.project.export.fps))
        return String(format: "%d:%02d.%02d", Int(t) / 60, Int(t) % 60, frames)
    }
}

// MARK: - Timeline

private struct TimelineStrip: View {
    let model: EditorModel
    private let perSecond: CGFloat = 46

    var body: some View {
        let p = model.project
        let starts = Timeline.starts(clips: p.clips, layout: p.layout)
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    ForEach(p.clips) { c in
                        Button {
                            model.selectedClip = c.id
                            model.tool = .clips
                            model.seek(starts[c.id] ?? 0)
                        } label: {
                            ClipThumb(clip: c)
                                .frame(width: max(30, CGFloat(c.outDuration) * perSecond), height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(model.selectedClip == c.id ? Color.white : .clear, lineWidth: 2))
                                .overlay(alignment: .bottomLeading) {
                                    HStack(spacing: 2) {
                                        if c.reversed { Image(systemName: "backward.fill") }
                                        if !c.keyframes.isEmpty { Image(systemName: "diamond.fill") }
                                        if c.originalName != nil { Image(systemName: c.isPhoto ? "wand.and.sparkles" : "move.3d") }
                                        if c.speed != 1 { Text(String(format: "%.2g×", c.speed)) }
                                        if c.muted { Image(systemName: "speaker.slash.fill") }
                                    }
                                    .font(.system(size: 9, weight: .bold)).padding(3)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                lane(p.overlays.map { ($0.id, $0.start, $0.duration, label(for: $0)) }, selected: model.selectedOverlay, tint: .pink) { id in
                    model.selectedOverlay = id
                    if let o = p.overlays.first(where: { $0.id == id }) {
                        model.tool = o.kind == .text ? .text : o.kind == .media ? .overlay : .stickers
                        model.seek(o.start)
                    }
                }
                lane(p.effects.filter { !$0.wholeTimeline }.map { ($0.id, $0.start, $0.duration, $0.kind.label) }, selected: model.selectedEffect, tint: .teal) { id in
                    model.selectedEffect = id; model.tool = .effects
                }
            }
            .padding(.horizontal, 14)
            .overlay(alignment: .topLeading) {
                Rectangle().fill(.white).frame(width: 2, height: 86)
                    .offset(x: 14 + CGFloat(model.time) * perSecond)
                    .allowsHitTesting(false)
            }
        }
    }

    private func label(for o: MomentOverlay) -> String {
        let mark = o.keyframes?.isEmpty == false ? "◆ " : ""
        return mark + kindLabel(o)
    }

    private func kindLabel(_ o: MomentOverlay) -> String {
        switch o.kind {
        case .text: o.text
        case .sticker: o.mediaName == nil ? o.text : "Cutout"
        case .media: o.mediaIsVideo ? "Video" : "Photo"
        case .drawing: "Drawing"
        }
    }

    @ViewBuilder
    private func lane(_ items: [(UUID, Double, Double, String)], selected: UUID?, tint: Color, tap: @escaping (UUID) -> Void) -> some View {
        if !items.isEmpty {
            ZStack(alignment: .leading) {
                Color.clear.frame(width: max(1, CGFloat(model.duration) * perSecond), height: 14)
                ForEach(items, id: \.0) { item in
                    Button { tap(item.0) } label: {
                        Text(item.3).font(.system(size: 9, weight: .semibold)).lineLimit(1).padding(.horizontal, 4)
                            .frame(width: max(18, CGFloat(item.2) * perSecond), height: 14, alignment: .leading)
                            .background(tint.opacity(selected == item.0 ? 0.9 : 0.45), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .offset(x: CGFloat(item.1) * perSecond)
                }
            }
        }
    }
}

struct ClipThumb: View {
    let clip: MomentClip
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color(white: 0.14)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Image(systemName: clip.isPhoto ? "photo" : "film").foregroundStyle(.tertiary) }
        }
        .task(id: "\(clip.id)-\(clip.inPoint)") { image = await Thumbs.image(for: clip) }
    }
}

enum Thumbs {
    static func image(for clip: MomentClip, max: CGFloat = 160) async -> CGImage? {
        if clip.isPhoto {
            guard let src = CGImageSourceCreateWithURL(clip.url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                                kCGImageSourceThumbnailMaxPixelSize: max] as CFDictionary)
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: max, height: max)
        return try? await gen.image(at: CMTime(seconds: clip.inPoint + 0.1, preferredTimescale: 600)).image
    }
}

// MARK: - Tools

private struct ToolBar: View {
    let model: EditorModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(EditorTool.allCases) { t in
                    Button { model.tool = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol).font(.system(size: 17, weight: .medium))
                            Text(t.label).font(.system(size: 10, weight: .medium))
                        }
                        .frame(width: 62, height: 46)
                        .foregroundStyle(model.tool == t ? Color.white : .secondary)
                        .background(model.tool == t ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

private struct ToolPanel: View {
    let model: EditorModel
    var body: some View {
        switch model.tool {
        case .clips: ClipsPanel(model: model)
        case .audio: AudioPanel(model: model)
        case .text: TextPanel(model: model)
        case .stickers: StickersPanel(model: model)
        case .effects: EffectsPanel(model: model)
        case .overlay: OverlayPanel(model: model)
        case .captions: CaptionsPanel(model: model)
        case .layout: LayoutPanel(model: model)
        case .export: ExportPanel(model: model)
        }
    }
}

#if os(iOS)
struct ShareItemsSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
struct ShareItemsSheet: View {
    let items: [URL]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready").font(.headline)
            ForEach(items, id: \.self) { u in ShareLink(item: u) { Label(u.lastPathComponent, systemImage: "square.and.arrow.up") } }
        }
        .padding(24)
    }
}
#endif

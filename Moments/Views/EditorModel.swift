// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case clips, audio, text, stickers, effects, overlay, captions, layout, export
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clips: "Edit"; case .audio: "Audio"; case .text: "Text"; case .stickers: "Stickers"; case .effects: "Effects"
        case .overlay: "Overlay"; case .captions: "Captions"; case .layout: "Layout"; case .export: "Export"
        }
    }
    var symbol: String {
        switch self {
        case .clips: "scissors"; case .audio: "waveform"; case .text: "textformat"; case .stickers: "face.smiling"
        case .effects: "sparkles"; case .overlay: "rectangle.on.rectangle"; case .captions: "captions.bubble"
        case .layout: "square.grid.2x2"; case .export: "square.and.arrow.up"
        }
    }
}

/// Editor state shared by the canvas, the timeline and every tool panel.
@MainActor
@Observable
final class EditorModel {
    let project: MomentProject
    let store: ProjectStore
    let player = AVPlayer()
    var time: Double = 0
    var isPlaying = false
    var tool: EditorTool = .clips
    var selectedClip: UUID?
    var selectedOverlay: UUID?
    var selectedEffect: UUID?
    var busy: String?
    var progress: Double?
    var status: String?
    var error: String?
    var shareItems: [URL]?
    var isBuilding = false
    private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var observer: Any?

    init(project: MomentProject, store: ProjectStore) {
        self.project = project
        self.store = store
        selectedClip = project.clips.first?.id
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                self.isPlaying = self.player.rate != 0
            }
        }
        rebuild(immediately: true)
    }

    var duration: Double { project.totalDuration }
    var frameStep: Double { 1 / Double(max(24, project.export.fps)) }

    // MARK: Selection

    var clipIndex: Int? { selectedClip.flatMap { id in project.clips.firstIndex { $0.id == id } } }
    var overlayIndex: Int? { selectedOverlay.flatMap { id in project.overlays.firstIndex { $0.id == id } } }
    var effectIndex: Int? { selectedEffect.flatMap { id in project.effects.firstIndex { $0.id == id } } }

    /// The clip under the playhead (first cell of the group in a collage).
    var clipAtPlayhead: Int? {
        let starts = Timeline.starts(clips: project.clips, layout: project.layout)
        return project.clips.indices.first { i in
            let s = starts[project.clips[i].id] ?? 0
            return time >= s && time < s + project.clips[i].outDuration
        }
    }

    // MARK: Changes

    /// Saves and re-renders the preview shortly after the last change.
    func commit() {
        rebuild(save: true)
    }

    func rebuild(immediately: Bool = false, save: Bool = false) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 350_000_000) }
            guard !Task.isCancelled, let self else { return }
            if save { self.store.save(self.project) }
            await self.buildPreview()
        }
    }

    private func buildPreview() async {
        guard !project.clips.isEmpty else { player.replaceCurrentItem(with: nil); return }
        isBuilding = true
        defer { isBuilding = false }
        let wasPlaying = isPlaying
        let at = time
        do {
            let (comp, video, mix) = try await CompositionExport.makeComposition(ExportSnapshot(project: project), preview: true)
            guard !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: comp)
            item.videoComposition = video
            item.audioMix = mix
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(seconds: min(at, max(0, duration - frameStep)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Transport

    func togglePlay() {
        if player.rate != 0 { player.pause(); isPlaying = false; return }
        if time >= duration - 0.05 { seek(0) }
        player.play(); isPlaying = true
    }

    func seek(_ t: Double) {
        let c = min(max(0, t), max(0, duration - 0.001))
        time = c
        player.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(_ frames: Int) {
        player.pause(); isPlaying = false
        seek(((time / frameStep).rounded() + Double(frames)) * frameStep)
    }

    // MARK: Clip edits

    func splitAtPlayhead() {
        guard let i = clipAtPlayhead else { status = "Move the playhead over a clip to split it."; return }
        let c = project.clips[i]
        let start = Timeline.starts(clips: project.clips, layout: project.layout)[c.id] ?? 0
        let local = time - start
        guard local > 0.1, c.outDuration - local > 0.1 else { status = "Too close to the edge of the clip to split."; return }
        var a = c
        a.outDuration = local
        a.animOut = .none
        var b = c.copy(inPoint: c.inPoint + (c.isPhoto ? 0 : local * c.speed), outDuration: c.outDuration - local)
        b.animIn = .none
        project.clips.replaceSubrange(i...i, with: [a, b])
        selectedClip = b.id
        status = String(format: "Split at %.2fs.", time)
        commit()
    }

    func deleteClip(_ i: Int) {
        project.clips.remove(at: i)
        selectedClip = project.clips.indices.contains(i) ? project.clips[i].id : project.clips.last?.id
        commit()
    }

    func moveClip(_ i: Int, by d: Int) {
        let j = i + d
        guard project.clips.indices.contains(j) else { return }
        project.clips.swapAt(i, j)
        commit()
    }

    func duplicateClip(_ i: Int) {
        let copy = project.clips[i].copy()
        project.clips.insert(copy, at: i + 1)
        selectedClip = copy.id
        commit()
    }

    // MARK: Overlays

    func addOverlay(_ o: MomentOverlay) {
        var o = o
        if o.start == 0, time > 0, time < duration - 0.3 { o.start = time }
        o.duration = min(o.duration, max(0.5, duration - o.start))
        project.overlays.append(o)
        selectedOverlay = o.id
        commit()
    }

    func removeOverlay(_ id: UUID) {
        project.overlays.removeAll { $0.id == id }
        if selectedOverlay == id { selectedOverlay = nil }
        commit()
    }

    // MARK: Keyframes

    func overlayLocal(_ o: MomentOverlay) -> Double { min(max(0, time - o.start), o.duration) }

    func overlayPose(_ id: UUID) -> OverlayKeyframe? {
        guard let o = project.overlays.first(where: { $0.id == id }) else { return nil }
        let s = Keyframes.overlay(o, at: overlayLocal(o))
        return OverlayKeyframe(t: overlayLocal(o), center: s.center, scale: s.scale, rotation: s.rotation, opacity: s.opacity)
    }

    /// Changes position, size, rotation or opacity. With keyframes, edits the one at the playhead or adds one there.
    func editOverlayPose(_ id: UUID, live: Bool = false, _ change: (inout OverlayKeyframe) -> Void) {
        guard let i = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        var o = project.overlays[i]
        let local = overlayLocal(o)
        if var keys = o.keyframes, !keys.isEmpty {
            if let k = keys.firstIndex(where: { abs($0.t - local) <= frameStep / 2 + 0.001 }) {
                change(&keys[k])
            } else {
                let s = Keyframes.overlay(o, at: local)
                var nk = OverlayKeyframe(t: local, center: s.center, scale: s.scale, rotation: s.rotation, opacity: s.opacity)
                change(&nk)
                keys.append(nk)
                keys.sort { $0.t < $1.t }
            }
            o.keyframes = keys
        } else {
            var base = OverlayKeyframe(t: 0, center: o.center, scale: o.scale, rotation: o.rotation, opacity: o.opacity)
            change(&base)
            o.center = base.center; o.scale = base.scale; o.rotation = base.rotation; o.opacity = base.opacity
        }
        project.overlays[i] = o
        if !live { commit() }
    }

    func addOverlayKeyframe(_ id: UUID) {
        guard let i = project.overlays.firstIndex(where: { $0.id == id }), let pose = overlayPose(id) else { return }
        var keys = project.overlays[i].keyframes ?? []
        guard !keys.contains(where: { abs($0.t - pose.t) <= frameStep / 2 + 0.001 }) else { return }
        keys.append(pose)
        keys.sort { $0.t < $1.t }
        project.overlays[i].keyframes = keys
        status = keys.count == 1
            ? String(format: "Keyframe at %.2fs. Move the playhead, then move, resize or turn it to add the next.", pose.t)
            : String(format: "Keyframe at %.2fs.", pose.t)
        commit()
    }

    func updateOverlayKeyframes(_ id: UUID, _ change: (inout [OverlayKeyframe]) -> Void) {
        guard let i = project.overlays.firstIndex(where: { $0.id == id }) else { return }
        var keys = project.overlays[i].keyframes ?? []
        change(&keys)
        if keys.isEmpty, let last = project.overlays[i].keyframes?.first {
            project.overlays[i].center = last.center; project.overlays[i].scale = last.scale
            project.overlays[i].rotation = last.rotation; project.overlays[i].opacity = last.opacity
        }
        project.overlays[i].keyframes = keys.isEmpty ? nil : keys
        commit()
    }

    func clipLocal(_ c: MomentClip) -> Double {
        let start = Timeline.starts(clips: project.clips, layout: project.layout)[c.id] ?? 0
        return min(max(0, time - start), c.outDuration)
    }

    func clipPose(_ id: UUID) -> ClipKeyframe {
        guard let c = project.clips.first(where: { $0.id == id }) else { return ClipKeyframe(t: 0) }
        return Keyframes.clip(c.keyframes, at: clipLocal(c)) ?? ClipKeyframe(t: clipLocal(c))
    }

    func editClipPose(_ id: UUID, _ change: (inout ClipKeyframe) -> Void) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let local = clipLocal(project.clips[i])
        var keys = project.clips[i].keyframes
        if let k = keys.firstIndex(where: { abs($0.t - local) <= frameStep / 2 + 0.001 }) {
            change(&keys[k])
        } else {
            var nk = Keyframes.clip(keys, at: local) ?? ClipKeyframe(t: local)
            nk.t = local
            nk.id = UUID()
            change(&nk)
            keys.append(nk)
            keys.sort { $0.t < $1.t }
        }
        project.clips[i].keyframes = keys
        commit()
    }

    // MARK: Long jobs

    func run(_ label: String, _ job: @escaping @MainActor () async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        Task {
            defer { busy = nil; progress = nil }
            do { try await job() } catch { self.error = error.localizedDescription }
        }
    }
}

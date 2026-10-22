// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Bindings that save and re-render

extension EditorModel {
    func clip<T>(_ id: UUID, _ kp: WritableKeyPath<MomentClip, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.clips.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in if let i = self.project.clips.firstIndex(where: { $0.id == id }) { self.project.clips[i][keyPath: kp] = v; self.commit() } })
    }
    func overlay<T>(_ id: UUID, _ kp: WritableKeyPath<MomentOverlay, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.overlays.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in if let i = self.project.overlays.firstIndex(where: { $0.id == id }) { self.project.overlays[i][keyPath: kp] = v; self.commit() } })
    }
    func effect<T>(_ id: UUID, _ kp: WritableKeyPath<MomentEffect, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.effects.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in if let i = self.project.effects.firstIndex(where: { $0.id == id }) { self.project.effects[i][keyPath: kp] = v; self.commit() } })
    }
    func caption<T>(_ id: UUID, _ kp: WritableKeyPath<MomentCaption, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.captions.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in if let i = self.project.captions.firstIndex(where: { $0.id == id }) { self.project.captions[i][keyPath: kp] = v; self.commit() } })
    }
    func prop<T>(_ kp: ReferenceWritableKeyPath<MomentProject, T>) -> Binding<T> {
        Binding(get: { self.project[keyPath: kp] }, set: { self.project[keyPath: kp] = $0; self.commit() })
    }
}

// MARK: - Small controls

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.lowercase)
            content
        }
        .padding(.bottom, 14)
    }
}

struct Chips<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Button { selection = item } label: {
                        Text(label(item)).font(.caption.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 7)
                            .background(selection == item ? Color.white : Color.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(selection == item ? Color.black : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ColorRow: View {
    @Binding var hex: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Hex.palette, id: \.self) { h in
                    let c = Hex.rgba(h)
                    Button { hex = h } label: {
                        Circle().fill(Color(red: c.0, green: c.1, blue: c.2)).frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(hex.uppercased() == h ? Color.white : Color.white.opacity(0.2), lineWidth: hex.uppercased() == h ? 3 : 1))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(
                    get: { let c = Hex.rgba(hex); return Color(red: c.0, green: c.1, blue: c.2) },
                    set: { hex = $0.hexString })
                ).labelsHidden()
            }
        }
    }
}

extension Color {
    var hexString: String {
        let c = self.resolve(in: EnvironmentValues())
        func b(_ v: Float) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", b(c.red), b(c.green), b(c.blue))
    }
}

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: String = "%.2f"
    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct WideButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        if prominent {
            Button(action: action) { Label(title, systemImage: symbol).frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent)
        } else {
            Button(action: action) { Label(title, systemImage: symbol).frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.bordered)
        }
    }
}

/// Timing, motion and placement shared by text, stickers, drawings and overlays.
struct OverlayTiming: View {
    let model: EditorModel
    let id: UUID

    private func pose(_ kp: WritableKeyPath<OverlayKeyframe, Double>, _ fallback: Double) -> Binding<Double> {
        Binding(get: { model.overlayPose(id)?[keyPath: kp] ?? fallback },
                set: { v in model.editOverlayPose(id) { $0[keyPath: kp] = v } })
    }

    var body: some View {
        let dur = max(0.5, model.duration)
        PanelSection(title: "timing") {
            ValueSlider(title: "Starts", value: model.overlay(id, \.start, fallback: 0), range: 0...dur, step: 0.05, format: "%.2fs")
            ValueSlider(title: "Length", value: model.overlay(id, \.duration, fallback: 3), range: 0.3...dur, step: 0.05, format: "%.2fs")
            HStack {
                Button("Start at playhead") { model.overlay(id, \.start, fallback: 0).wrappedValue = model.time }
                Button("End at playhead") {
                    if let o = model.project.overlays.first(where: { $0.id == id }), model.time > o.start + 0.2 {
                        model.overlay(id, \.duration, fallback: 3).wrappedValue = model.time - o.start
                    }
                }
                Button("Whole video") {
                    model.overlay(id, \.start, fallback: 0).wrappedValue = 0
                    model.overlay(id, \.duration, fallback: 3).wrappedValue = model.duration
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        PanelSection(title: "animation in") { Chips(items: MotionAnim.allCases, selection: model.overlay(id, \.animIn, fallback: .none)) { $0.label } }
        PanelSection(title: "animation out") { Chips(items: MotionAnim.allCases, selection: model.overlay(id, \.animOut, fallback: .none)) { $0.label } }
        let o = model.project.overlays.first { $0.id == id }
        let keys = o?.keyframes ?? []
        PanelSection(title: "placement") {
            ValueSlider(title: "Scale", value: pose(\.scale, 1), range: 0.1...4, format: "%.2f×")
            ValueSlider(title: "Rotation", value: pose(\.rotation, 0), range: -360...360, step: 1, format: "%.0f°")
            ValueSlider(title: "Opacity", value: pose(\.opacity, 1), range: 0...1, format: "%.2f")
            ValueSlider(title: "Across", value: Binding(get: { model.overlayPose(id)?.center.x ?? 0.5 },
                                                     set: { v in model.editOverlayPose(id) { $0.center.x = v } }), range: -0.2...1.2, format: "%.2f")
            ValueSlider(title: "Down", value: Binding(get: { model.overlayPose(id)?.center.y ?? 0.5 },
                                                   set: { v in model.editOverlayPose(id) { $0.center.y = v } }), range: -0.2...1.2, format: "%.2f")
            Text(keys.isEmpty ? "Drag the handle on the preview to move it." : "With keyframes, any change here or on the preview sets a keyframe at the playhead.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        PanelSection(title: "keyframes") {
            KeyframeStrip(times: keys.map { ($0.id, $0.t, $0.ease) }, local: o.map(model.overlayLocal) ?? 0, step: model.frameStep,
                          add: { model.addOverlayKeyframe(id) },
                          jump: { t in model.seek((o?.start ?? 0) + t) },
                          remove: { kid in model.updateOverlayKeyframes(id) { $0.removeAll { $0.id == kid } } },
                          ease: { kid, e in model.updateOverlayKeyframes(id) { ks in if let i = ks.firstIndex(where: { $0.id == kid }) { ks[i].ease = e } } },
                          clear: { model.updateOverlayKeyframes(id) { $0.removeAll() } })
        }
        HStack {
            Button {
                if let o = model.project.overlays.first(where: { $0.id == id }) {
                    var c = o; c.id = UUID(); c.center = NormPoint(x: min(0.9, o.center.x + 0.05), y: min(0.9, o.center.y + 0.05))
                    model.project.overlays.append(c); model.selectedOverlay = c.id; model.commit()
                }
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { model.removeOverlay(id) } label: { Label("Delete", systemImage: "trash") }
        }
        .buttonStyle(.bordered)
    }
}

/// Keyframes along one item: add at the playhead, jump to one, set its easing, delete.
struct KeyframeStrip: View {
    let times: [(UUID, Double, KeyEase)]
    let local: Double
    let step: Double
    let add: () -> Void
    let jump: (Double) -> Void
    let remove: (UUID) -> Void
    let ease: (UUID, KeyEase) -> Void
    let clear: () -> Void

    var body: some View {
        let here = times.first { abs($0.1 - local) <= step / 2 + 0.001 }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: add) { Label(here == nil ? "Add keyframe" : "Keyframe here", systemImage: here == nil ? "diamond" : "diamond.fill") }
                    .buttonStyle(.borderedProminent).disabled(here != nil)
                Spacer()
                if !times.isEmpty { Button("Clear all", role: .destructive, action: clear).buttonStyle(.bordered).controlSize(.small) }
            }
            if !times.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(times, id: \.0) { k in
                            Button { jump(k.1) } label: {
                                Label(String(format: "%.2fs", k.1), systemImage: here?.0 == k.0 ? "diamond.fill" : "diamond")
                                    .font(.caption.monospacedDigit()).padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(here?.0 == k.0 ? Color.white.opacity(0.25) : Color.white.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let here {
                    Chips(items: KeyEase.allCases, selection: Binding(get: { here.2 }, set: { ease(here.0, $0) })) { $0.label }
                    Button(role: .destructive) { remove(here.0) } label: { Label("Delete this keyframe", systemImage: "trash") }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Text("Move the playhead onto a keyframe to change its easing (how it moves to the next one).")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                Text("Add a keyframe, move the playhead, then change position, size, rotation or opacity. It animates between them.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Edit (clips)

struct ClipsPanel: View {
    let model: EditorModel
    @State private var picks: [PhotosPickerItem] = []
    @State private var showCamera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "add") {
                HStack {
                    PhotosPicker(selection: $picks, maxSelectionCount: 50, matching: .any(of: [.videos, .images])) {
                        Label("Photos & video", systemImage: "plus.circle.fill").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    #if os(iOS)
                    Button { showCamera = true } label: { Label("Record", systemImage: "video.fill").frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .buttonStyle(.bordered)
                    #endif
                }
                if model.project.clips.count > 1 {
                    WideButton(title: "Auto-fit: strongest shot first, cut to the beat", symbol: "wand.and.stars") { autoFit() }
                }
            }
            if let i = model.clipIndex {
                ClipEditor(model: model, id: model.project.clips[i].id)
            } else if !model.project.clips.isEmpty {
                Text("Tap a clip in the timeline to edit it.").font(.caption).foregroundStyle(.secondary).padding(.bottom, 14)
            }
            PanelSection(title: "transition between clips") {
                Chips(items: MomentTransition.allCases, selection: model.prop(\.transition)) { $0.label }
            }
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            model.run("Importing \(items.count) item\(items.count == 1 ? "" : "s")…") {
                for item in items {
                    let c = try await MediaImport.clip(from: item)
                    model.project.clips.append(c)
                    if model.selectedClip == nil { model.selectedClip = c.id }
                }
                picks = []
                model.commit()
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { url in
                showCamera = false
                guard let url else { return }
                model.run("Adding recording…") {
                    let d = try await AVURLAsset(url: url).load(.duration).seconds
                    let c = MomentClip(url: url, duration: d, isPhoto: false, outDuration: d)
                    model.project.clips.append(c); model.selectedClip = c.id; model.commit()
                }
            }
        }
        #endif
    }

    private func autoFit() {
        model.run("Auto-fitting on device…") {
            model.project.clips = await AutoFit.order(model.project.clips)
            if let music = model.project.musicURL, let marks = try? await BeatSync.detectBeats(url: music) {
                model.project.beatMarks = marks
                model.project.clips = BeatSync.retimedClips(model.project.clips, to: marks)
            }
            model.commit()
            model.status = "Strongest shot first, cuts on the beat."
        }
    }
}

private struct ClipEditor: View {
    let model: EditorModel
    let id: UUID
    @State private var voice: VoiceEffect = .none
    @State private var enhance = true

    private func clipPose(_ kp: WritableKeyPath<ClipKeyframe, Double>) -> Binding<Double> {
        Binding(get: { model.clipPose(id)[keyPath: kp] }, set: { v in model.editClipPose(id) { $0[keyPath: kp] = v } })
    }

    var body: some View {
        let c = model.project.clips.first { $0.id == id }!
        let i = model.project.clips.firstIndex { $0.id == id }!
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ClipThumb(clip: c).frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.isPhoto ? "Photo" : "Video").font(.headline)
                    Text(String(format: "Clip %d of %d · %.2fs", i + 1, model.project.clips.count, c.outDuration)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.moveClip(i, by: -1) } label: { Image(systemName: "arrow.left") }.disabled(i == 0)
                Button { model.moveClip(i, by: 1) } label: { Image(systemName: "arrow.right") }.disabled(i == model.project.clips.count - 1)
                Button { model.duplicateClip(i) } label: { Image(systemName: "plus.square.on.square") }
                Button(role: .destructive) { model.deleteClip(i) } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .padding(.bottom, 14)

            PanelSection(title: "trim") {
                let maxLen = c.isPhoto ? 15 : max(0.3, (c.duration - c.inPoint) / max(0.25, c.speed))
                ValueSlider(title: "Length", value: model.clip(id, \.outDuration, fallback: 2), range: 0.2...max(0.3, maxLen), step: 1.0 / 30, format: "%.2fs")
                if !c.isPhoto {
                    ValueSlider(title: "Starts in source", value: model.clip(id, \.inPoint, fallback: 0), range: 0...max(0.05, c.duration - 0.2), step: 1.0 / 30, format: "%.2fs")
                }
                Text("Split at the playhead with the scissors above the timeline. Step frame by frame with the arrows.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if !c.isPhoto {
                PanelSection(title: "speed") {
                    ValueSlider(title: "Speed", value: model.clip(id, \.speed, fallback: 1), range: 0.25...4, step: 0.05, format: "%.2f×")
                    Chips(items: [0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0], selection: model.clip(id, \.speed, fallback: 1)) { String(format: "%g×", $0) }
                }
                PanelSection(title: "sound") {
                    Toggle("Mute this clip", isOn: model.clip(id, \.muted, fallback: false))
                    ValueSlider(title: "Volume", value: model.clip(id, \.volume, fallback: 1), range: 0...2, step: 0.05, format: "%.2f×")
                    Chips(items: VoiceEffect.allCases, selection: $voice) { $0.label }
                    Toggle("Enhance voice (cut rumble, lift clarity, even out level)", isOn: $enhance).font(.subheadline)
                    HStack {
                        Button { applyVoice(c) } label: { Label("Apply to this clip", systemImage: "waveform.badge.magnifyingglass") }
                        if c.audioName != nil {
                            Button("Original sound") { model.clip(id, \.audioName, fallback: nil).wrappedValue = nil }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                PanelSection(title: "reverse") {
                    Toggle("Play backwards", isOn: Binding(get: { c.reversed }, set: { on in setReversed(c, on) }))
                    Text("Made on this device. A reversed clip plays without its own sound.").font(.caption).foregroundStyle(.tertiary)
                }
            }
            PanelSection(title: c.isPhoto ? "photo motion" : "motion") {
                Chips(items: ClipMotion.allCases, selection: model.clip(id, \.motion, fallback: .none)) { $0.label }
            }
            PanelSection(title: "animation in") { Chips(items: MotionAnim.allCases, selection: model.clip(id, \.animIn, fallback: .none)) { $0.label } }
            PanelSection(title: "animation out") { Chips(items: MotionAnim.allCases, selection: model.clip(id, \.animOut, fallback: .none)) { $0.label } }
            PanelSection(title: "background") {
                Chips(items: ClipBackground.allCases, selection: model.clip(id, \.background, fallback: .fill)) { $0.label }
                Text("Cutout keeps the person and drops the background (Vision, on device). Green screen keys out green.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            PanelSection(title: "keyframes") {
                KeyframeStrip(times: c.keyframes.map { ($0.id, $0.t, $0.ease) }, local: model.clipLocal(c), step: model.frameStep,
                              add: { model.editClipPose(id) { _ in } },
                              jump: { t in model.seek((Timeline.starts(clips: model.project.clips, layout: model.project.layout)[id] ?? 0) + t) },
                              remove: { kid in model.project.clips[i].keyframes.removeAll { $0.id == kid }; model.commit() },
                              ease: { kid, e in if let k = model.project.clips[i].keyframes.firstIndex(where: { $0.id == kid }) { model.project.clips[i].keyframes[k].ease = e; model.commit() } },
                              clear: { model.project.clips[i].keyframes.removeAll(); model.commit() })
                ValueSlider(title: "Zoom", value: clipPose(\.zoom), range: 0.3...4, format: "%.2f×")
                ValueSlider(title: "Move across", value: clipPose(\.x), range: -1...1, format: "%.2f")
                ValueSlider(title: "Move down", value: clipPose(\.y), range: -1...1, format: "%.2f")
                ValueSlider(title: "Rotation", value: clipPose(\.rotation), range: -360...360, step: 1, format: "%.0f°")
                ValueSlider(title: "Opacity", value: clipPose(\.opacity), range: 0...1, format: "%.2f")
            }
            if c.isPhoto || c.originalName != nil {
                GeneratePanel(model: model, id: id)
            }
            if !c.isPhoto {
                DatamoshPanel(model: model, id: id)
            }
            PanelSection(title: "adjust") {
                ValueSlider(title: "Exposure", value: model.clip(id, \.adjust.exposure, fallback: 0), range: -1.5...1.5)
                ValueSlider(title: "Contrast", value: model.clip(id, \.adjust.contrast, fallback: 1), range: 0.5...1.6)
                ValueSlider(title: "Saturation", value: model.clip(id, \.adjust.saturation, fallback: 1), range: 0...2)
                ValueSlider(title: "Warmth", value: model.clip(id, \.adjust.warmth, fallback: 0), range: -1...1)
                ValueSlider(title: "Relight (lift shadows, soft key light)", value: model.clip(id, \.adjust.relight, fallback: 0), range: 0...1)
                ValueSlider(title: "Sharpen", value: model.clip(id, \.adjust.sharpen, fallback: 0), range: 0...1)
                Button("Reset adjustments") { model.clip(id, \.adjust, fallback: ClipAdjust()).wrappedValue = ClipAdjust() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if c.isPhoto {
                WideButton(title: "Make a cutout sticker from this photo", symbol: "person.crop.square.filled.and.at.rectangle") {
                    model.run("Cutting out the subject…") {
                        let url = try await CutoutSticker.make(from: c.url)
                        model.addOverlay(MomentOverlay(kind: .sticker, mediaName: url.lastPathComponent, center: NormPoint(x: 0.5, y: 0.55), widthFrac: 0.6))
                        model.tool = .stickers
                    }
                }
                .padding(.bottom, 14)
            }
        }
    }

    private func applyVoice(_ c: MomentClip) {
        let effect = voice, enh = enhance
        model.run("Processing sound on device…") {
            let raw = try await AudioFX.extract(from: c.url)
            let out = try await AudioFX.process(raw, effect: effect, enhance: enh)
            model.clip(id, \.audioName, fallback: nil).wrappedValue = out.lastPathComponent
            model.status = "\(effect.label)\(enh ? " + enhanced" : "") sound applied."
        }
    }

    private func setReversed(_ c: MomentClip, _ on: Bool) {
        if !on || c.reversedName != nil { model.clip(id, \.reversed, fallback: false).wrappedValue = on; return }
        model.run("Reversing on device…") {
            let url = try await ClipReverse.reverse(c.url)
            if let i = model.project.clips.firstIndex(where: { $0.id == id }) {
                model.project.clips[i].reversedName = url.lastPathComponent
                model.project.clips[i].reversed = true
                model.commit()
            }
        }
    }
}

/// Datamosh baked into the clip on this device: the clip's motion drags old pixels instead of drawing new ones.
private struct DatamoshPanel: View {
    let model: EditorModel
    let id: UUID
    @State private var mode: Datamosh.Mode = .fromPrevious
    @State private var length = 1.5
    @State private var amount = 3.0
    @State private var leak = 0.1

    var body: some View {
        let clips = model.project.clips
        let i = clips.firstIndex { $0.id == id }
        PanelSection(title: "datamosh") {
            Chips(items: Datamosh.Mode.allCases, selection: $mode) { $0.label }
            ValueSlider(title: "Length", value: $length, range: 0.3...4, step: 0.1, format: "%.1fs")
            ValueSlider(title: "Amount", value: $amount, range: 1...8, step: 0.5, format: "%.1f×")
            if mode == .melt { ValueSlider(title: "Leak", value: $leak, range: 0...0.5, format: "%.2f") }
            if let i, clips[i].reversed {
                Text("Turn reverse off to datamosh this clip.").font(.caption).foregroundStyle(.secondary)
            } else if let i, mode == .fromPrevious, i == 0 {
                Text("This is the first clip, so there is no clip before it to mosh from.").font(.caption).foregroundStyle(.secondary)
            } else if let i {
                WideButton(title: "Mosh", symbol: "square.stack.3d.forward.dottedline", prominent: true) { mosh(i) }
            }
            Text(mode.note + (mode == .fromPrevious ? "" : " Starts at the playhead when it is on this clip.") + " Made on this device with Vision motion, in 16-pixel blocks like a codec.")
                .font(.caption).foregroundStyle(.tertiary)
            if let i, let original = clips[i].moshSourceName {
                WideButton(title: "Undo datamosh", symbol: "arrow.uturn.backward") { undo(original) }
            }
        }
    }

    private func mosh(_ i: Int) {
        let c = model.project.clips[i]
        let previous = i > 0 ? model.project.clips[i - 1] : nil
        let m = mode, len = length, amt = amount, lk = m == .melt ? leak : 0
        let start = m == .fromPrevious ? c.inPoint : c.inPoint + model.clipLocal(c) * max(0.1, c.speed)
        model.progress = 0
        model.run("Datamoshing on device…") {
            var stuck: CGImage?
            if m == .fromPrevious, let previous { stuck = try await Datamosh.lastFrame(of: previous) }
            let url = try await Datamosh.render(c.url, stuck: stuck, mode: m, start: start, length: len, amount: amt, leak: lk) { f in
                Task { @MainActor in model.progress = f }
            }
            let sound = c.audioName == nil ? try? await AudioFX.extract(from: c.url) : nil
            guard let j = model.project.clips.firstIndex(where: { $0.id == id }) else { return }
            model.project.clips[j].moshSourceName = model.project.clips[j].moshSourceName ?? c.url.lastPathComponent
            model.project.clips[j].url = url
            if let sound { model.project.clips[j].audioName = sound.lastPathComponent }
            model.commit()
            model.status = "\(m.label) datamosh baked in. Undo brings the clip back."
        }
    }

    private func undo(_ original: String) {
        guard let j = model.project.clips.firstIndex(where: { $0.id == id }) else { return }
        model.project.clips[j].url = MediaImport.mediaDir.appendingPathComponent(original)
        model.project.clips[j].moshSourceName = nil
        model.commit()
        model.status = "Datamosh removed."
    }
}

/// Generated motion and restyles for a photo clip, all on this device.
private struct GeneratePanel: View {
    let model: EditorModel
    let id: UUID
    @State private var path: PhotoAnimate.Path = .pushIn
    @State private var seconds = 4.0
    @State private var strength = 0.7
    @State private var style: Restyle.Style = .animation
    @State private var prompt = ""

    var body: some View {
        let c = model.project.clips.first { $0.id == id }
        VStack(alignment: .leading, spacing: 0) {
            if let c, c.isPhoto {
                PanelSection(title: "animate photo (3d)") {
                    Chips(items: PhotoAnimate.Path.allCases, selection: $path) { $0.label }
                    ValueSlider(title: "Length", value: $seconds, range: 2...8, step: 0.5, format: "%.1fs")
                    ValueSlider(title: "Depth", value: $strength, range: 0.1...1, format: "%.2f")
                    WideButton(title: "Animate", symbol: "move.3d", prominent: true) { animate(c) }
                    Text("Depth is estimated on this device (the photo's own Portrait depth, or the Depth Anything model), then the camera moves through the scene so near things move more than far things. It becomes a video clip.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                PanelSection(title: "restyle") {
                    Chips(items: Restyle.Style.allCases, selection: $style) { $0.label }
                    TextField("Add words (optional), e.g. at the beach, in winter", text: $prompt).textFieldStyle(.roundedBorder)
                    WideButton(title: "Restyle photo", symbol: "wand.and.sparkles") { restyle(c) }
                    Text("Made on this device by Apple's Image Playground. Needs Apple Intelligence turned on. nu.moments never uses the external ChatGPT style.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            if let c, let original = c.originalName {
                WideButton(title: "Back to the original photo", symbol: "arrow.uturn.backward") { revert(c, to: original) }
                    .padding(.bottom, 14)
            }
        }
    }

    private func replace(_ change: (inout MomentClip) -> Void) {
        guard let i = model.project.clips.firstIndex(where: { $0.id == id }) else { return }
        change(&model.project.clips[i])
        model.commit()
    }

    private func animate(_ c: MomentClip) {
        let p = path, secs = seconds, amt = strength, src = c.url
        model.progress = 0
        model.run("Animating in 3D on device…") {
            let r = try await PhotoAnimate.render(photo: src, path: p, seconds: secs, strength: amt) { f in Task { @MainActor in model.progress = f } }
            replace { clip in
                clip.originalName = clip.originalName ?? clip.url.lastPathComponent
                clip.url = r.url
                clip.isPhoto = false
                clip.duration = r.duration
                clip.inPoint = 0
                clip.outDuration = r.duration
                clip.motion = .none
                clip.muted = true
            }
            model.status = "\(p.label) made from \(r.depth.rawValue)."
        }
    }

    private func restyle(_ c: MomentClip) {
        let s = style, words = prompt, src = c.url
        model.run("Restyling on device…") {
            let url = try await Restyle.restyle(photo: src, style: s, prompt: words)
            replace { clip in
                clip.originalName = clip.originalName ?? clip.url.lastPathComponent
                clip.url = url
            }
            model.status = "\(s.label) restyle done. You can animate it too."
        }
    }

    private func revert(_ c: MomentClip, to original: String) {
        replace { clip in
            clip.url = MediaImport.mediaDir.appendingPathComponent(original)
            clip.isPhoto = true
            clip.duration = 2.4
            clip.inPoint = 0
            clip.outDuration = min(clip.outDuration, 15)
            clip.originalName = nil
        }
        model.status = "Back to the original photo."
    }
}

// MARK: - Audio

struct AudioPanel: View {
    let model: EditorModel
    @State private var showMusic = false
    @State private var bpm: Double = 120
    @State private var recorder = VoiceRecorder()
    @State private var voice: VoiceEffect = .none
    @State private var enhance = true
    @State private var rawVoiceover: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "music") {
                HStack {
                    Button { showMusic = true } label: { Label(model.project.musicURL == nil ? "Choose a track" : "Change track", systemImage: "music.note").frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .buttonStyle(.borderedProminent)
                    if model.project.musicURL != nil {
                        Button(role: .destructive) { model.project.musicURL = nil; model.project.beatMarks = []; model.commit() } label: { Image(systemName: "trash").padding(.vertical, 8) }
                            .buttonStyle(.bordered)
                    }
                }
                if let m = model.project.musicURL { Text(m.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                ValueSlider(title: "Generated beat", value: $bpm, range: 70...170, step: 1, format: "%.0f BPM")
                WideButton(title: "Use a generated beat", symbol: "metronome") {
                    model.project.musicURL = BeatTrack.generate(bpm: bpm, seconds: max(30, model.duration + 2))
                    model.commit(); model.status = "Beat made on this device at \(Int(bpm)) BPM."
                }
                if model.project.musicURL != nil {
                    ValueSlider(title: "Music volume", value: model.prop(\.musicVolume), range: 0...1, step: 0.05, format: "%.2f")
                    WideButton(title: "Cut clips to the beat", symbol: "waveform.path", prominent: true) {
                        model.run("Finding the beat…") {
                            guard let m = model.project.musicURL else { return }
                            let marks = try await BeatSync.detectBeats(url: m)
                            model.project.beatMarks = marks
                            model.project.clips = BeatSync.retimedClips(model.project.clips, to: marks)
                            model.commit(); model.status = "\(marks.count) beats found; clips re-timed."
                        }
                    }
                }
            }
            PanelSection(title: "voice-over") {
                if recorder.isRecording {
                    WideButton(title: String(format: "Stop  %.1fs", recorder.elapsed), symbol: "stop.circle.fill", prominent: true) {
                        model.player.pause(); model.player.isMuted = false
                        if let url = recorder.stop() { rawVoiceover = url; model.project.voiceoverURL = url; model.commit() }
                    }
                } else {
                    WideButton(title: model.project.voiceoverURL == nil ? "Record a voice-over" : "Record again", symbol: "mic.fill", prominent: true) {
                        model.run("Starting the microphone…") {
                            try await recorder.start()
                            model.player.isMuted = true
                            model.seek(0); model.player.play()
                        }
                    }
                    Text("The video plays silently while you talk, so you can time it.").font(.caption).foregroundStyle(.tertiary)
                }
                if model.project.voiceoverURL != nil {
                    ValueSlider(title: "Voice-over volume", value: model.prop(\.voiceoverVolume), range: 0...2, step: 0.05, format: "%.2f")
                    Chips(items: VoiceEffect.allCases, selection: $voice) { $0.label }
                    Toggle("Enhance voice", isOn: $enhance)
                    HStack {
                        Button { applyVoice() } label: { Label("Apply voice effect", systemImage: "waveform.badge.plus") }
                        Button(role: .destructive) { model.project.voiceoverURL = nil; model.commit() } label: { Label("Remove", systemImage: "trash") }
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("Licensed music catalogues and trending audio are Instagram's; nu.moments uses your own tracks or beats it makes on the device.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .fileImporter(isPresented: $showMusic, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .movie]) { result in
            guard case .success(let url) = result, url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            model.project.musicURL = MediaImport.music(from: url)
            model.commit()
        }
    }

    private func applyVoice() {
        guard let src = rawVoiceover ?? model.project.voiceoverURL else { return }
        if rawVoiceover == nil { rawVoiceover = src }
        let effect = voice, enh = enhance
        model.run("Processing voice on device…") {
            model.project.voiceoverURL = try await AudioFX.process(src, effect: effect, enhance: enh)
            model.commit(); model.status = "\(effect.label) voice applied."
        }
    }
}

// MARK: - Text

struct TextPanel: View {
    let model: EditorModel
    @State private var draft = ""

    var body: some View {
        let texts = model.project.overlays.filter { $0.kind == .text }
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "add text") {
                HStack {
                    TextField("Type something", text: $draft).textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        model.addOverlay(MomentOverlay(kind: .text, text: t, font: model.project.template.titleFont, colorHex: "FFFFFF",
                                                       center: NormPoint(x: 0.5, y: 0.4), duration: 3))
                        draft = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if !texts.isEmpty {
                PanelSection(title: "on this video") {
                    Chips(items: texts.map(\.id), selection: Binding(get: { model.selectedOverlay ?? texts[0].id }, set: { model.selectedOverlay = $0 })) { id in
                        String(texts.first { $0.id == id }?.text.prefix(18) ?? "")
                    }
                }
            }
            if let i = model.overlayIndex, model.project.overlays[i].kind == .text {
                let id = model.project.overlays[i].id
                PanelSection(title: "text") {
                    TextField("Text", text: model.overlay(id, \.text, fallback: ""), axis: .vertical).textFieldStyle(.roundedBorder)
                }
                PanelSection(title: "font") { Chips(items: TextFont.allCases, selection: model.overlay(id, \.font, fallback: .sans)) { $0.label } }
                PanelSection(title: "colour") { ColorRow(hex: model.overlay(id, \.colorHex, fallback: "FFFFFF")) }
                PanelSection(title: "style") {
                    ValueSlider(title: "Size", value: model.overlay(id, \.fontSize, fallback: 72), range: 20...220, step: 1, format: "%.0f pt")
                    Toggle("Outline", isOn: model.overlay(id, \.outline, fallback: false))
                    Toggle("Background box", isOn: Binding(
                        get: { model.project.overlays[i].boxHex != nil },
                        set: { model.overlay(id, \.boxHex, fallback: nil).wrappedValue = $0 ? "0A0B0D" : nil }))
                    if model.project.overlays[i].boxHex != nil {
                        ColorRow(hex: Binding(get: { model.project.overlays[i].boxHex ?? "0A0B0D" },
                                              set: { model.overlay(id, \.boxHex, fallback: nil).wrappedValue = $0 }))
                    }
                }
                OverlayTiming(model: model, id: id)
            }
        }
    }
}

// MARK: - Stickers and drawing

struct StickersPanel: View {
    let model: EditorModel
    @State private var photo: PhotosPickerItem?
    @State private var showDraw = false
    private static let emoji = Array("❤️🔥✨😂😍🥹😎🤩🥳🙌👏💯⭐️🌈☀️🌙⚡️🎉🎂🎵🎶📍✈️🌊🌸🌿🍕☕️🍷💄👗👟🏀⚽️🏋️🧘🐶🐱🦋💥💫👀💬✅❗️❓➡️⬆️🕺💃📸🎬🏆💎🫶😭🤯😴").map(String.init)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "stickers") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                    ForEach(Self.emoji, id: \.self) { e in
                        Button { model.addOverlay(MomentOverlay(kind: .sticker, text: e, fontSize: 90, center: NormPoint(x: 0.5, y: 0.5), duration: 3, animIn: .bounce)) } label: {
                            Text(e).font(.system(size: 28)).frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            PanelSection(title: "cutouts and drawing") {
                HStack {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Cutout from a photo", systemImage: "person.crop.square.filled.and.at.rectangle").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    #if os(iOS)
                    Button { showDraw = true } label: { Label("Draw", systemImage: "pencil.tip").frame(maxWidth: .infinity).padding(.vertical, 8) }
                        .buttonStyle(.bordered)
                    #endif
                }
                Text("The cutout lifts the subject from the photo on this device and keeps it as a reusable sticker.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if let i = model.overlayIndex, [.sticker, .drawing].contains(model.project.overlays[i].kind) {
                let o = model.project.overlays[i]
                if o.kind == .sticker {
                    PanelSection(title: "size") {
                        if o.mediaName == nil {
                            ValueSlider(title: "Size", value: model.overlay(o.id, \.fontSize, fallback: 90), range: 30...300, step: 1, format: "%.0f")
                        } else {
                            ValueSlider(title: "Width", value: model.overlay(o.id, \.widthFrac, fallback: 0.5), range: 0.1...1.2, format: "%.2f")
                        }
                    }
                }
                OverlayTiming(model: model, id: o.id)
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            model.run("Cutting out the subject…") {
                defer { photo = nil }
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let src = MediaImport.mediaDir.appendingPathComponent("sticker-src-\(UUID().uuidString.prefix(8)).jpg")
                try data.write(to: src)
                let url = try await CutoutSticker.make(from: src)
                model.addOverlay(MomentOverlay(kind: .sticker, mediaName: url.lastPathComponent, center: NormPoint(x: 0.5, y: 0.55), widthFrac: 0.6))
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showDraw) {
            DrawingSheet(aspect: model.project.format.size) { url in
                showDraw = false
                guard let url else { return }
                var o = MomentOverlay(kind: .drawing, mediaName: url.lastPathComponent, center: NormPoint(x: 0.5, y: 0.5), duration: model.duration)
                o.animIn = .fade; o.animOut = .none
                model.addOverlay(o)
            }
        }
        #endif
    }
}

// MARK: - Effects and filters

struct EffectsPanel: View {
    let model: EditorModel
    @State private var query = ""
    @State private var group: EffectGroup?
    @State private var whole = false

    var body: some View {
        let list = EffectKind.allCases.filter { k in
            (group == nil || k.group == group) && (query.isEmpty || k.label.localizedCaseInsensitiveContains(query))
        }
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "filter") { Chips(items: MomentLook.allCases, selection: model.prop(\.look)) { $0.label } }
            PanelSection(title: "effects (\(EffectKind.allCases.count))") {
                TextField("Search effects", text: $query).textFieldStyle(.roundedBorder)
                Chips(items: [nil] + EffectGroup.allCases.map(Optional.some), selection: $group) { $0?.label ?? "All" }
                Toggle("Apply to the whole video (adjustment layer)", isOn: $whole).font(.subheadline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(list) { k in
                        Button { add(k) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: k.symbol).font(.system(size: 16))
                                Text(k.label).font(.caption2).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !whole { Text("Effects start at the playhead and last 2 seconds; adjust below.").font(.caption).foregroundStyle(.tertiary) }
            }
            if !model.project.effects.isEmpty {
                PanelSection(title: "applied") {
                    Chips(items: model.project.effects.map(\.id),
                          selection: Binding(get: { model.selectedEffect ?? model.project.effects[0].id }, set: { model.selectedEffect = $0 })) { id in
                        let e = model.project.effects.first { $0.id == id }
                        return (e?.kind.label ?? "") + (e?.wholeTimeline == true ? " · all" : "")
                    }
                }
            }
            if let i = model.effectIndex {
                let id = model.project.effects[i].id
                PanelSection(title: model.project.effects[i].kind.label) {
                    ValueSlider(title: "Intensity", value: model.effect(id, \.intensity, fallback: 0.7), range: 0...1)
                    ValueSlider(title: "Speed", value: model.effect(id, \.speed, fallback: 1), range: 0.25...4, format: "%.2f×")
                    Toggle("Whole video", isOn: model.effect(id, \.wholeTimeline, fallback: false))
                    if !model.project.effects[i].wholeTimeline {
                        ValueSlider(title: "Starts", value: model.effect(id, \.start, fallback: 0), range: 0...max(0.5, model.duration), step: 0.05, format: "%.2fs")
                        ValueSlider(title: "Length", value: model.effect(id, \.duration, fallback: 2), range: 0.2...max(0.5, model.duration), step: 0.05, format: "%.2fs")
                        Button("Start at playhead") { model.effect(id, \.start, fallback: 0).wrappedValue = model.time }.buttonStyle(.bordered).controlSize(.small)
                    }
                    Button(role: .destructive) {
                        model.project.effects.removeAll { $0.id == id }; model.selectedEffect = nil; model.commit()
                    } label: { Label("Remove effect", systemImage: "trash") }.buttonStyle(.bordered)
                }
            }
        }
    }

    private func add(_ k: EffectKind) {
        let e = MomentEffect(kind: k, intensity: 0.7, start: whole ? 0 : model.time,
                             duration: whole ? model.duration : min(2, max(0.3, model.duration - model.time)), wholeTimeline: whole)
        model.project.effects.append(e)
        model.selectedEffect = e.id
        model.commit()
    }
}

// MARK: - Overlay (picture in picture, green screen)

struct OverlayPanel: View {
    let model: EditorModel
    @State private var pick: PhotosPickerItem?

    var body: some View {
        let media = model.project.overlays.filter { $0.kind == .media }
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "add an overlay") {
                PhotosPicker(selection: $pick, matching: .any(of: [.videos, .images])) {
                    Label("Photo or video on top", systemImage: "rectangle.on.rectangle").frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                Text("Use green screen to key out a green background, or cutout to keep only the person.").font(.caption).foregroundStyle(.tertiary)
            }
            if !media.isEmpty {
                PanelSection(title: "overlays") {
                    Chips(items: media.map(\.id), selection: Binding(get: { model.selectedOverlay ?? media[0].id }, set: { model.selectedOverlay = $0 })) { id in
                        let n = (media.firstIndex { $0.id == id } ?? 0) + 1
                        return "\(media.first { $0.id == id }?.mediaIsVideo == true ? "Video" : "Photo") \(n)"
                    }
                }
            }
            if let i = model.overlayIndex, model.project.overlays[i].kind == .media {
                let id = model.project.overlays[i].id
                PanelSection(title: "cut out") { Chips(items: MediaKey.allCases, selection: model.overlay(id, \.key, fallback: .none)) { $0.label } }
                PanelSection(title: "size") {
                    ValueSlider(title: "Width", value: model.overlay(id, \.widthFrac, fallback: 0.45), range: 0.1...1, format: "%.2f")
                    Button("Full frame") {
                        model.overlay(id, \.widthFrac, fallback: 0.45).wrappedValue = 1
                        model.overlay(id, \.center, fallback: NormPoint(x: 0.5, y: 0.5)).wrappedValue = NormPoint(x: 0.5, y: 0.5)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                OverlayTiming(model: model, id: id)
            }
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            model.run("Adding overlay…") {
                defer { pick = nil }
                let c = try await MediaImport.clip(from: item)
                model.addOverlay(MomentOverlay(kind: .media, mediaName: c.url.lastPathComponent, mediaIsVideo: !c.isPhoto,
                                               center: NormPoint(x: 0.68, y: 0.32), widthFrac: 0.45,
                                               duration: c.isPhoto ? 3 : min(c.duration, max(1, model.duration)), animIn: .pop))
            }
        }
    }
}

// MARK: - Captions

struct CaptionsPanel: View {
    let model: EditorModel
    @State private var style: CaptionStyle = .pop
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "auto captions") {
                WideButton(title: "Caption speech on this device", symbol: "captions.bubble", prominent: true) {
                    let s = style
                    model.run("Listening on device…") {
                        let caps = try await AutoCaptions.captions(for: ExportSnapshot(project: model.project))
                        model.project.captions = caps.map { var c = $0; c.style = s; return c }
                        model.commit(); model.status = "\(caps.count) caption lines. Nothing left the device."
                    }
                }
                Text("Speech is recognised with on-device recognition only, from clip sound and your voice-over.").font(.caption).foregroundStyle(.tertiary)
            }
            PanelSection(title: "style") {
                Chips(items: CaptionStyle.allCases, selection: Binding(get: { model.project.captions.first?.style ?? style }, set: { s in
                    style = s
                    for i in model.project.captions.indices { model.project.captions[i].style = s }
                    model.commit()
                })) { $0.label }
                Chips(items: TextFont.allCases, selection: model.prop(\.captionLook.font)) { $0.label }
                Chips(items: CaptionPosition.allCases, selection: model.prop(\.captionLook.position)) { $0.label }
                ValueSlider(title: "Size", value: model.prop(\.captionLook.size), range: 28...110, step: 1, format: "%.0f pt")
                Text("Text colour").font(.subheadline)
                ColorRow(hex: model.prop(\.captionLook.colorHex))
                Toggle("Highlight each word as it's spoken", isOn: model.prop(\.captionLook.wordHighlight))
                if model.project.captionLook.wordHighlight { ColorRow(hex: model.prop(\.captionLook.highlightHex)) }
            }
            PanelSection(title: "add a line") {
                HStack {
                    TextField("Caption at the playhead", text: $draft).textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        model.project.captions.append(MomentCaption(text: t, style: style, start: model.time, duration: min(2.4, max(0.6, model.duration - model.time))))
                        model.project.captions.sort { $0.start < $1.start }
                        draft = ""; model.commit()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if !model.project.captions.isEmpty {
                PanelSection(title: "lines") {
                    ForEach(model.project.captions) { c in
                        HStack(spacing: 8) {
                            Button { model.seek(c.start) } label: { Text(String(format: "%.1fs", c.start)).font(.caption.monospacedDigit()) }
                                .buttonStyle(.bordered).controlSize(.small)
                            TextField("", text: model.caption(c.id, \.text, fallback: "")).textFieldStyle(.roundedBorder)
                            Button(role: .destructive) { model.project.captions.removeAll { $0.id == c.id }; model.commit() } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Layout, templates, kits

struct LayoutPanel: View {
    let model: EditorModel
    @State private var kitName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "format") { Chips(items: ProjectFormat.allCases, selection: model.prop(\.format)) { $0.label } }
            PanelSection(title: "layout") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                    ForEach(CollageLayout.allCases) { l in
                        Button { model.project.layout = l; model.commit() } label: {
                            VStack(spacing: 4) {
                                Image(systemName: l.symbol).font(.title3)
                                Text(l.label).font(.caption2).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(model.project.layout == l ? Color.white.opacity(0.22) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Collages play clips side by side, filling each cell in order.").font(.caption).foregroundStyle(.tertiary)
                Text("Background").font(.subheadline)
                ColorRow(hex: model.prop(\.backdropHex))
            }
            PanelSection(title: "apply a template to these clips") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MomentTemplate.catalogue) { t in
                            Button { model.project.apply(template: t); model.commit(); model.status = "\(t.title) applied." } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [t.accent.opacity(0.7), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 70, height: 90)
                                    Text(t.title).font(.caption2).lineLimit(1).frame(width: 70, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            PanelSection(title: "kits") {
                HStack {
                    TextField("Kit name", text: $kitName).textFieldStyle(.roundedBorder)
                    Button("Save style as kit") {
                        let n = kitName.trimmingCharacters(in: .whitespaces)
                        model.store.saveKit(model.project.makeKit(named: n.isEmpty ? model.project.title : n))
                        kitName = ""; model.status = "Kit saved: colours, text, captions, filter, effects and audio."
                    }
                    .buttonStyle(.bordered)
                }
                if !model.store.kits.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.store.kits) { k in
                                Button { model.project.apply(kit: k); model.commit(); model.status = "Kit \(k.name) applied." } label: {
                                    HStack(spacing: 4) {
                                        ForEach(k.palette.prefix(3), id: \.self) { h in
                                            let c = Hex.rgba(h); Circle().fill(Color(red: c.0, green: c.1, blue: c.2)).frame(width: 10, height: 10)
                                        }
                                        Text(k.name).font(.caption.weight(.medium))
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Color.white.opacity(0.1), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Export

struct ExportPanel: View {
    let model: EditorModel
    @State private var seamless = false
    @State private var panels = 3

    var body: some View {
        let empty = model.project.clips.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "quality") {
                Chips(items: ExportResolution.allCases, selection: model.prop(\.export.resolution)) { $0.label }
                Chips(items: [24, 30, 60], selection: model.prop(\.export.fps)) { "\($0) fps" }
                Toggle("HEVC (smaller files, HDR-ready)", isOn: model.prop(\.export.hevc))
                Text("No watermark. Up to 4K at 60 fps.").font(.caption).foregroundStyle(.tertiary)
            }
            PanelSection(title: "reel") {
                WideButton(title: "Export and share", symbol: "square.and.arrow.up", prominent: true) { exportReel(save: false) }.disabled(empty)
                WideButton(title: "Save to Photos", symbol: "photo.on.rectangle") { exportReel(save: true) }.disabled(empty)
            }
            PanelSection(title: "carousel") {
                Toggle("Seamless (one picture across the slides)", isOn: $seamless)
                if seamless { Stepper("Slides: \(panels)", value: $panels, in: 2...10) }
                Text(seamless ? "One photo spreads across every slide, or several clips line up edge to edge."
                              : "4:5 slides. Photos become stills, videos stay videos, with the same filter, text and stickers.")
                    .font(.caption).foregroundStyle(.tertiary)
                HStack {
                    Button { carousel(save: false) } label: { Label("Share slides", systemImage: "square.and.arrow.up.on.square").frame(maxWidth: .infinity).padding(.vertical, 8) }
                    Button { carousel(save: true) } label: { Label("Save slides", systemImage: "rectangle.stack").frame(maxWidth: .infinity).padding(.vertical, 8) }
                }
                .buttonStyle(.bordered).disabled(empty)
            }
            PanelSection(title: "project") {
                Picker("Folder", selection: Binding(get: { model.project.folder }, set: { model.store.move(model.project, to: $0) })) {
                    Text("None").tag(String?.none)
                    ForEach(model.store.folders, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Button { let c = model.store.duplicate(model.project); model.status = "Duplicated as \(c.title)." } label: { Label("Duplicate project", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
            }
            Text("Everything renders on this device and stays here until you share it.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func exportReel(save: Bool) {
        model.player.pause()
        let snap = ExportSnapshot(project: model.project)
        model.progress = 0
        model.run("Rendering \(model.project.export.resolution.label)…") {
            let url = try await CompositionExport.export(snap) { p in Task { @MainActor in model.progress = p } }
            model.store.save(model.project)
            if save { try await PhotosSave.saveVideo(url); model.status = "Saved to Photos." } else { model.shareItems = [url] }
        }
    }

    private func carousel(save: Bool) {
        model.player.pause()
        let snap = ExportSnapshot(project: model.project)
        let s = seamless, n = panels
        model.run("Making slides…") {
            let slides = try await CarouselExport.slides(for: snap, seamless: s, panels: n)
            if save { try await PhotosSave.save(slides); model.status = "\(slides.count) slides saved to Photos." } else { model.shareItems = slides }
        }
    }
}

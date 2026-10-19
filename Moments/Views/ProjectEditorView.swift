// SPDX-License-Identifier: AGPL-3.0-only

import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ProjectEditorView: View {
    @Environment(ProjectStore.self) private var store
    @Bindable var project: MomentProject
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showMusic = false
    @State private var isAnalyzing = false
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var errorText: String?
    @State private var captionDraft = ""
    @State private var captionStyle: CaptionStyle = .pop
    @State private var player: AVPlayer?
    @State private var isBuildingPreview = false
    @State private var isAutoCaptioning = false
    @State private var isAutoFitting = false
    @State private var statusText: String?
    @State private var beatBPM: Double = 120
    @State private var shareItems: [Any]? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                templateHeader
                styleSection
                previewSection
                clipsSection
                musicSection
                captionsSection
                exportSection
            }
            .padding(20)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(project.title)
        .momentsNavChrome()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") {
                    store.save(project)
                }
            }
        }
        .onChange(of: pickerItems) { _, items in
            Task { await importClips(items) }
        }
        .fileImporter(isPresented: $showMusic, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav]) { result in
            if case .success(let url) = result {
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                project.musicURL = MediaImport.music(from: url)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .sheet(item: Binding(
            get: { exportURL.map { ExportPayload(url: $0) } },
            set: { exportURL = $0?.url }
        )) { payload in
            ShareSheet(url: payload.url)
        }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            if let shareItems { ShareItemsSheet(items: shareItems) }
        }
    }

    private var templateHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.template.title)
                .font(.title2.weight(.semibold))
            Text(project.template.blurb)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Untitled moment", text: $project.title)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("format, look & transitions")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                Text("Format").font(.subheadline); Spacer()
                Picker("Format", selection: $project.format) {
                    ForEach(ProjectFormat.allCases) { f in Text(f.label).tag(f) }
                }.pickerStyle(.segmented).frame(maxWidth: 260)
            }
            HStack {
                Text("Look").font(.subheadline); Spacer()
                Picker("Look", selection: $project.look) {
                    ForEach(MomentLook.allCases) { l in Text(l.label).tag(l) }
                }
            }
            HStack(spacing: 8) {
                Label(project.template.transition.label, systemImage: "arrow.left.and.right")
                Text("· from \(project.template.title)")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary)
            Text("Look, transitions and captions are rendered into the preview and the export — what you see is the file.")
                .font(.caption).foregroundStyle(.tertiary)
            if let statusText {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: project.format) { _, _ in store.save(project); player = nil }
        .onChange(of: project.look) { _, _ in store.save(project); player = nil }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("preview")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(white: 0.08))
                    .aspectRatio(project.format.size.width / project.format.size.height, contentMode: .fit)
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(project.format.size.width / project.format.size.height, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(project.clips.isEmpty ? "Add clips, then build a preview." : "Build a preview to watch it here.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 20)
                    }
                }
            }
            Button {
                Task { await buildPreview() }
            } label: {
                if isBuildingPreview { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 10) }
                else { Label("Build preview", systemImage: "play.circle").frame(maxWidth: .infinity).padding(.vertical, 10) }
            }
            .buttonStyle(.bordered)
            .disabled(project.clips.isEmpty || isBuildingPreview)
            if !project.captions.isEmpty, let first = project.captions.first {
                Text(first.text).font(.headline).padding(10)
                    .background(project.template.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var clipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("clips")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 24, matching: .any(of: [.videos, .images])) {
                Label(project.clips.isEmpty ? "Add photos & video" : "Add more", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            ForEach(Array(project.clips.enumerated()), id: \.element.id) { index, clip in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: clip.isPhoto ? "photo" : "film")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clip.url.lastPathComponent).lineLimit(1).font(.subheadline)
                            Text(String(format: "%.1fs on timeline", project.clips[index].outDuration))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { if index > 0 { project.clips.swapAt(index, index - 1); store.save(project) } } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { if index < project.clips.count - 1 { project.clips.swapAt(index, index + 1); store.save(project) } } label: { Image(systemName: "chevron.down") }
                            .disabled(index == project.clips.count - 1)
                        Button(role: .destructive) { project.clips.remove(at: index); store.save(project) } label: { Image(systemName: "trash") }
                    }
                    Slider(value: $project.clips[index].outDuration, in: 0.5...5, step: 0.1)
                    HStack {
                        Text(String(format: "%.1fs", project.clips[index].outDuration)).font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text(String(format: "starts %.1fs", project.clips[index].inPoint)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if !clip.isPhoto {
                        Slider(value: $project.clips[index].inPoint, in: 0...max(0.1, clip.duration - 0.4), step: 0.1)
                        Picker("Speed", selection: $project.clips[index].speed) {
                            Text("0.5×").tag(0.5); Text("1×").tag(1.0); Text("2×").tag(2.0)
                        }.pickerStyle(.segmented)
                    }
                    HStack(spacing: 10) {
                        Button { splitClip(at: index) } label: { Label("Split", systemImage: "scissors") }
                        Button { duplicateClip(at: index) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        if !clip.isPhoto {
                            Button { project.clips[index].muted.toggle(); store.save(project) } label: {
                                Label(project.clips[index].muted ? "Muted" : "Sound", systemImage: project.clips[index].muted ? "speaker.slash" : "speaker.wave.2")
                            }
                        }
                        if clip.isPhoto {
                            Button { Task { await liftSubject(at: index) } } label: { Label("Lift subject", systemImage: "person.crop.rectangle") }
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !project.clips.isEmpty {
                Text(String(format: "Total %.1fs · %d clips", project.totalDuration, project.clips.count))
                    .font(.caption).foregroundStyle(.secondary)
                Button { Task { await autoFit() } } label: {
                    if isAutoFitting { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 10) }
                    else { Label("Auto-fit: best shot first, cut to the beat", systemImage: "wand.and.stars").frame(maxWidth: .infinity).padding(.vertical, 10) }
                }.buttonStyle(.bordered).disabled(isAutoFitting)
            }
        }
    }

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("music & beat sync")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                showMusic = true
            } label: {
                Label(project.musicURL == nil ? "Choose a track" : "Change track", systemImage: "music.note")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Generated beat").font(.subheadline); Spacer(); Text("\(Int(beatBPM)) BPM").font(.caption).foregroundStyle(.secondary) }
                Slider(value: $beatBPM, in: 70...160, step: 1)
                Button {
                    project.musicURL = BeatTrack.generate(bpm: beatBPM)
                    store.save(project)
                    statusText = "Beat track generated on this device at \(Int(beatBPM)) BPM."
                } label: { Label("Use a generated beat track", systemImage: "metronome").frame(maxWidth: .infinity).padding(.vertical, 10) }
                .buttonStyle(.bordered)
            }
            if project.musicURL != nil {
                HStack { Text("Music volume").font(.subheadline); Spacer(); Text("\(Int(project.musicVolume * 100))%").font(.caption).foregroundStyle(.secondary) }
                Slider(value: $project.musicVolume, in: 0...1, step: 0.05)
                    .onChange(of: project.musicVolume) { _, _ in store.save(project) }
                Button {
                    Task { await runBeatSync() }
                } label: {
                    if isAnalyzing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        Label("Cut to the beat", systemImage: "waveform.path")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(project.clips.isEmpty || isAnalyzing)
                if !project.beatMarks.isEmpty {
                    Text("\(project.beatMarks.count) onsets · clips re-timed on device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var captionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("captions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Button { Task { await autoCaptions() } } label: {
                if isAutoCaptioning { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 10) }
                else { Label("Auto captions from speech (on device)", systemImage: "captions.bubble").frame(maxWidth: .infinity).padding(.vertical, 10) }
            }.buttonStyle(.bordered).disabled(project.clips.allSatisfy { $0.isPhoto } || isAutoCaptioning)
            Picker("Style", selection: $captionStyle) {
                ForEach(CaptionStyle.allCases) { s in Text(s.label).tag(s) }
            }.pickerStyle(.segmented)
            HStack {
                TextField("Add a line", text: $captionDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let t = captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    let start = project.clips.prefix(project.captions.count).reduce(0.0) { $0 + $1.duration }
                    project.captions.append(MomentCaption(text: t, style: captionStyle, start: start, duration: 2.2))
                    captionDraft = ""
                    store.save(project)
                }
                .disabled(captionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(project.captions) { c in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.text).font(.body.weight(.medium))
                        Text(c.style.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        project.captions.removeAll { $0.id == c.id }; store.save(project)
                    } label: { Image(systemName: "trash") }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(project.template.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("export")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                Task { await export() }
            } label: {
                if isExporting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    Label("Export reel", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(project.clips.isEmpty || isExporting)
            Button { Task { await saveReelToPhotos() } } label: {
                Label("Save reel to Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.bordered).disabled(project.clips.isEmpty || isExporting)
            Button { Task { await exportCarousel(save: true) } } label: {
                Label("Save carousel slides to Photos", systemImage: "rectangle.stack").frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.bordered).disabled(project.clips.isEmpty || isExporting)
            Button { Task { await exportCarousel(save: false) } } label: {
                Label("Share carousel slides", systemImage: "square.and.arrow.up.on.square").frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.bordered).disabled(project.clips.isEmpty || isExporting)
            Button { let copy = store.duplicate(project); statusText = "Duplicated as \(copy.title). Find it under 'on this device'." } label: {
                Label("Duplicate project", systemImage: "doc.on.doc").frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.bordered).disabled(project.clips.isEmpty)
            Text("Stays on this device until you share it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func buildPreview() async {
        isBuildingPreview = true
        defer { isBuildingPreview = false }
        do {
            let snap = ExportSnapshot(project: project)
            let (comp, videoComp, audioMix) = try await CompositionExport.makeComposition(snap)
            let item = AVPlayerItem(asset: comp)
            item.videoComposition = videoComp
            item.audioMix = audioMix
            let p = AVPlayer(playerItem: item)
            player = p
            p.play()
        } catch { errorText = error.localizedDescription }
    }

    private func splitClip(at index: Int) {
        let clip = project.clips[index]
        let half = clip.outDuration / 2
        guard half >= 0.35 else { return }
        var a = clip; a.outDuration = half
        var b = clip; b = MomentClip(url: clip.url, duration: clip.duration, isPhoto: clip.isPhoto, inPoint: clip.inPoint + (clip.isPhoto ? 0 : half * clip.speed), outDuration: half)
        b.speed = clip.speed; b.muted = clip.muted
        project.clips.replaceSubrange(index...index, with: [a, b])
        store.save(project)
    }
    private func duplicateClip(at index: Int) {
        let c = project.clips[index]
        let copy = MomentClip(url: c.url, duration: c.duration, isPhoto: c.isPhoto, inPoint: c.inPoint, outDuration: c.outDuration)
        var cc = copy; cc.speed = c.speed; cc.muted = c.muted
        project.clips.insert(cc, at: index + 1); store.save(project)
    }
    private func liftSubject(at index: Int) async {
        do {
            let snap = ExportSnapshot(project: project)
            let url = try await SubjectLift.lift(photoURL: project.clips[index].url, accent: snap)
            project.clips[index].url = url
            store.save(project); statusText = "Subject lifted on device — soft edge over a blurred backdrop. Original photo kept in your library."
        } catch { errorText = error.localizedDescription }
    }
    private func autoFit() async {
        isAutoFitting = true; defer { isAutoFitting = false }
        project.clips = await AutoFit.order(project.clips)
        if let music = project.musicURL {
            if let marks = try? await BeatSync.detectBeats(url: music) {
                project.beatMarks = marks; project.clips = BeatSync.retimedClips(project.clips, to: marks)
            }
        }
        store.save(project); player = nil
        statusText = "Auto-fit done on device: strongest shot first, clips re-timed."
    }
    private func autoCaptions() async {
        isAutoCaptioning = true; defer { isAutoCaptioning = false }
        do {
            let snap = ExportSnapshot(project: project)
            let caps = try await AutoCaptions.captions(for: snap)
            project.captions = caps.map { var c = $0; c.style = captionStyle; return c }
            store.save(project); statusText = "\(caps.count) captions recognised on this device. Nothing was sent anywhere."
        } catch { errorText = error.localizedDescription }
    }
    private func saveReelToPhotos() async {
        isExporting = true; defer { isExporting = false }
        do { let url = try await CompositionExport.export(project); try await PhotosSave.saveVideo(url); statusText = "Reel saved to your photo library." }
        catch { errorText = error.localizedDescription }
    }
    private func exportCarousel(save: Bool) async {
        isExporting = true; defer { isExporting = false }
        do {
            let snap = ExportSnapshot(project: project)
            let slides = try await CarouselExport.slides(for: snap)
            if save { try await PhotosSave.saveImages(slides); statusText = "\(slides.count) carousel slides saved to Photos." }
            else { shareItems = slides }
        } catch { errorText = error.localizedDescription }
    }

    private func importClips(_ items: [PhotosPickerItem]) async {
        defer { pickerItems = [] }
        for item in items {
            do {
                let clip = try await MediaImport.clip(from: item)
                project.clips.append(clip)
                store.save(project)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func runBeatSync() async {
        guard let music = project.musicURL else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let marks = try await BeatSync.detectBeats(url: music)
            project.beatMarks = marks
            project.clips = BeatSync.retimedClips(project.clips, to: marks)
            store.save(project)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func export() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try await CompositionExport.export(project)
            store.save(project)
            exportURL = url
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct ExportPayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct ShareItemsSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
struct ShareItemsSheet: View {
    let items: [Any]
    var body: some View { Text("\(items.count) slides ready").padding() }
}
struct ShareSheet: View {
    let url: URL
    var body: some View {
        VStack(spacing: 16) {
            Text("Exported")
                .font(.headline)
            Text(url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
#endif

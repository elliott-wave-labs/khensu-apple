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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                templateHeader
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

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("preview")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(white: 0.08))
                    .aspectRatio(9/16, contentMode: .fit)
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(9/16, contentMode: .fit)
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
                    Text(String(format: "%.1fs", project.clips[index].outDuration)).font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !project.clips.isEmpty {
                Text(String(format: "Total %.1fs · %d clips", project.totalDuration, project.clips.count))
                    .font(.caption).foregroundStyle(.secondary)
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
            if project.musicURL != nil {
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
            Text("Stays on this device until you share it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func buildPreview() async {
        isBuildingPreview = true
        defer { isBuildingPreview = false }
        do {
            let snap = ExportSnapshot(project: project)
            let (comp, videoComp) = try await CompositionExport.makeComposition(snap)
            let item = AVPlayerItem(asset: comp)
            item.videoComposition = videoComp
            let p = AVPlayer(playerItem: item)
            player = p
            p.play()
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
#else
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

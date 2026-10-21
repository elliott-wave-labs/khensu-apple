// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import SwiftUI

struct HomeView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var path: NavigationPath
    @State private var query = ""
    @State private var category: TemplateCategory?
    @State private var folder: String? = nil
    @State private var showUnfiled = false
    @State private var newFolder = ""
    @State private var askFolder = false
    @State private var ideaDraft = ""
    @State private var suggestions: [ForYou.Suggestion] = []
    @State private var loadingForYou = false
    @State private var busy: String?
    @State private var errorText: String?
    @State private var showCamera = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                quickActions
                forYou
                templates
                projects
                ideas
                if !store.kits.isEmpty { kits }
                Text("Everything is made on this device. No upload to score a clip, no tracking for ads. Tips go 100% to the person.")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("ñü.mømëntš")
        .momentsNavChrome()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { url in
                showCamera = false
                guard let url else { return }
                Task {
                    let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 3
                    open(template: MomentTemplate.catalogue.first { $0.id == "clean-cut" } ?? MomentTemplate.catalogue[0],
                         clips: [MomentClip(url: url, duration: d, isPhoto: false, outDuration: d)])
                }
            }
        }
        #endif
        .overlay(alignment: .top) {
            if let busy {
                HStack(spacing: 8) { ProgressView(); Text(busy).font(.caption) }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassEffect(.regular, in: Capsule()).padding(.top, 8)
            }
        }
        .alert("New folder", isPresented: $askFolder) {
            TextField("Name", text: $newFolder)
            Button("Create") { store.addFolder(newFolder); newFolder = "" }
            Button("Cancel", role: .cancel) { newFolder = "" }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Boost the moments you actually keep.")
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.4)
            Text("Reels, stories and carousels: templates, effects, captions, voice-over and beat sync, all on this device.")
                .font(.body).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            action("New", "plus") { path.append(MomentTemplate.catalogue.first { $0.id == "clean-cut" } ?? MomentTemplate.catalogue[0]) }
            #if os(iOS)
            action("Record", "video.fill") { showCamera = true }
            #endif
            action("Beat sync", "waveform") { if let t = MomentTemplate.catalogue.first(where: { $0.id == "pulse" }) { path.append(t) } }
            action("Collage", "square.grid.2x2") { if let t = MomentTemplate.catalogue.first(where: { $0.layout != .single }) { path.append(t) } }
        }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3.weight(.semibold))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: For You

    private var forYou: some View {
        section("for you") {
            if suggestions.isEmpty {
                Button { loadForYou() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles.rectangle.stack").font(.title2.weight(.semibold))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Suggest moments from my library").font(.headline)
                            Text("Only when you tap. Grouped on this device by day, trip and favourites. Nothing is made until you open one.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer()
                        if loadingForYou { ProgressView() }
                    }
                    .padding(18)
                    .background(LinearGradient(colors: [Color(red: 0.94, green: 0.66, blue: 0.78).opacity(0.35), Color(red: 0.49, green: 0.88, blue: 0.78).opacity(0.25)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(suggestions) { s in
                            Button { openSuggestion(s) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [Color(red: 0.94, green: 0.66, blue: 0.78).opacity(0.5), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                                        .frame(width: 150, height: 190)
                                        .overlay(Image(systemName: "play.fill").font(.title).foregroundStyle(.white.opacity(0.8)))
                                    Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(s.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 150)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button("Clear suggestions") { suggestions = [] }.font(.caption)
            }
        }
    }

    private func loadForYou() {
        loadingForYou = true
        Task {
            defer { loadingForYou = false }
            do { suggestions = try await ForYou.suggestions() } catch { errorText = error.localizedDescription }
        }
    }

    private func openSuggestion(_ s: ForYou.Suggestion) {
        busy = "Copying \(s.assetIDs.count) items from this device…"
        Task {
            defer { busy = nil }
            let clips = await ForYou.clips(for: s)
            guard !clips.isEmpty else { errorText = "Those items are not on this device (only in iCloud), so they were skipped."; return }
            open(template: MomentTemplate.catalogue.first { $0.id == s.templateID } ?? MomentTemplate.catalogue[0], clips: clips, title: s.title)
        }
    }

    private func open(template: MomentTemplate, clips: [MomentClip], title: String? = nil) {
        let p = store.open(template)
        if let title { p.title = title }
        for var c in clips {
            if template.motion != .none, c.isPhoto { c.motion = template.motion }
            if template.clipAnimIn != .none { c.animIn = template.clipAnimIn }
            p.clips.append(c)
        }
        store.save(p)
        path.append(p.id)
    }

    // MARK: Templates

    private var templates: some View {
        let used = TemplateCategory.allCases.filter { c in MomentTemplate.catalogue.contains { $0.category == c } }
        let list = MomentTemplate.catalogue.filter { t in
            (category == nil || t.category == category) &&
                (query.isEmpty || t.title.localizedCaseInsensitiveContains(query) || t.blurb.localizedCaseInsensitiveContains(query) || t.category.label.localizedCaseInsensitiveContains(query))
        }
        return section("templates (\(MomentTemplate.catalogue.count))") {
            TextField("Search templates", text: $query).textFieldStyle(.roundedBorder)
            Chips(items: [nil] + used.map(Optional.some), selection: $category) { $0?.label ?? "All" }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(list) { t in
                    Button { path.append(t) } label: { TemplateCard(template: t) }.buttonStyle(.plain)
                }
            }
            if list.isEmpty { Text("No templates match.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Projects and folders

    private var projects: some View {
        let shown = store.projects.filter { p in
            if showUnfiled { return p.folder == nil }
            return folder == nil || p.folder == folder
        }
        return section("on this device") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    folderChip("All", selected: folder == nil && !showUnfiled) { folder = nil; showUnfiled = false }
                    folderChip("Unfiled", selected: showUnfiled) { folder = nil; showUnfiled = true }
                    ForEach(store.folders, id: \.self) { f in
                        folderChip(f, selected: folder == f) { folder = f; showUnfiled = false }
                            .contextMenu { Button("Delete folder", role: .destructive) { store.removeFolder(f); if folder == f { folder = nil } } }
                    }
                    Button { askFolder = true } label: { Label("Folder", systemImage: "folder.badge.plus").font(.caption.weight(.medium)) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if shown.isEmpty {
                Text(store.projects.isEmpty ? "Your projects will appear here." : "Nothing in this folder.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.id) { p in
                Button { path.append(p.id) } label: {
                    HStack(spacing: 12) {
                        if let c = p.clips.first {
                            ClipThumb(clip: c).frame(width: 46, height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.title).font(.headline)
                            Text("\(p.clips.count) clips · \(String(format: "%.0fs", p.totalDuration)) · \(p.format.label)\(p.folder.map { " · \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Menu("Move to folder") {
                        Button("None") { store.move(p, to: nil) }
                        ForEach(store.folders, id: \.self) { f in Button(f) { store.move(p, to: f) } }
                    }
                    Button("Duplicate") { _ = store.duplicate(p) }
                    Button("Delete", role: .destructive) { store.remove(p) }
                }
            }
        }
    }

    private func folderChip(_ title: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title).font(.caption.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 7)
                .background(selected ? Color.white : Color.white.opacity(0.1), in: Capsule())
                .foregroundStyle(selected ? Color.black : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Ideas

    private var ideas: some View {
        section("ideas") {
            HStack {
                TextField("Jot down an idea for later", text: $ideaDraft).textFieldStyle(.roundedBorder)
                Button("Add") {
                    let t = ideaDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    store.addIdea(MomentIdea(text: t)); ideaDraft = ""
                }
                .buttonStyle(.bordered)
            }
            ForEach(store.ideas) { idea in
                HStack(spacing: 10) {
                    Button {
                        var i = idea; i.done.toggle(); store.updateIdea(i)
                    } label: { Image(systemName: idea.done ? "checkmark.circle.fill" : "circle") }
                        .buttonStyle(.plain)
                    Text(idea.text).strikethrough(idea.done).foregroundStyle(idea.done ? .secondary : .primary)
                    Spacer()
                    Button("Start") {
                        let p = store.open(MomentTemplate.catalogue.first { $0.id == "clean-cut" } ?? MomentTemplate.catalogue[0])
                        p.title = idea.text
                        store.save(p); path.append(p.id)
                    }
                    .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    Button(role: .destructive) { store.removeIdea(idea) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var kits: some View {
        section("kits") {
            ForEach(store.kits) { k in
                HStack(spacing: 8) {
                    ForEach(k.palette.prefix(4), id: \.self) { h in
                        let c = Hex.rgba(h); Circle().fill(Color(red: c.0, green: c.1, blue: c.2)).frame(width: 14, height: 14)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k.name).font(.subheadline.weight(.semibold))
                        Text("\(k.look.label) · \(k.textFont.label) · \(k.captionStyle.label) captions").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { store.removeKit(k) } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Apply a kit from the Layout tool in any project.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).textCase(.lowercase)
            content()
        }
    }
}

struct TemplateCard: View {
    let template: MomentTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [template.accent.opacity(0.55), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay { TemplateSample(id: template.id, fill: template.format != .wide) }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom).frame(height: 56)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.category.label).font(.caption2.weight(.semibold))
                        Text("\(template.look.label) · \(template.transition.label) · \(template.format.label)")
                            .font(.caption2).foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(10)
                    .foregroundStyle(.white.opacity(0.9))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(template.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(template.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

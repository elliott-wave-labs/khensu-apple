// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreTransferable
import KhensuKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Posting a video to the public feed: pick it, add a caption, upload.
struct FeedComposeView: View {
    let feed: FeedModel
    let defaultHandle: String

    @Environment(\.dismiss) private var dismiss
    @State private var pick: PhotosPickerItem?
    @State private var video: URL?
    @State private var preview: AVPlayer?
    @State private var loadingPick = false
    @State private var handle = ""
    @State private var caption = ""
    @State private var error: String?

    private var busy: Bool { feed.postStep != .idle }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let preview {
                        PlayerLayerView(player: preview, gravity: .resizeAspect)
                            .frame(height: 320)
                            .frame(maxWidth: .infinity)
                            .clipShape(.rect(cornerRadius: 16))
                            .onAppear { preview.isMuted = true; preview.play() }
                    }
                    PhotosPicker(selection: $pick, matching: .videos, preferredItemEncoding: .current) {
                        Label(video == nil ? "Choose a video" : "Choose another video", systemImage: "video.badge.plus")
                    }
                    .disabled(busy)
                    if loadingPick { ProgressView("Getting the video ready") }
                }
                Section {
                    TextField("Handle", text: $handle)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Caption", text: $caption, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    Text("Posts on the feed are public. Anyone can see the video, the caption and the handle.")
                }
                if busy {
                    Section {
                        switch feed.postStep {
                        case .uploadingVideo(let fraction):
                            ProgressView("Uploading video", value: fraction)
                        case .uploadingPoster:
                            ProgressView("Uploading cover")
                        case .publishing:
                            ProgressView("Posting")
                        default:
                            ProgressView("Preparing")
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New post")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post", action: post)
                        .disabled(busy || video == nil || handle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .interactiveDismissDisabled(busy)
        }
        .onAppear { if handle.isEmpty { handle = defaultHandle } }
        .onChange(of: pick) { _, item in load(item) }
        .onDisappear { preview?.pause() }
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        loadingPick = true
        error = nil
        Task {
            defer { loadingPick = false }
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    error = "That video couldn't be opened."
                    return
                }
                if let old = video { try? FileManager.default.removeItem(at: old) }
                video = movie.url
                preview = AVPlayer(url: movie.url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func post() {
        guard let video else { return }
        error = nil
        preview?.pause()
        Task {
            do {
                try await feed.publish(video: video, handle: handle, caption: caption)
                try? FileManager.default.removeItem(at: video)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A picked movie copied into the app's temporary directory.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("feed-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

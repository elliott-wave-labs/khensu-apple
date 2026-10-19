// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import Foundation
import KhensuKit
import Observation
import os

/// State for the public feed: pages from `GET /v1/feed`, the post flow and reports.
@MainActor @Observable
final class FeedModel {
    enum Phase: Equatable { case offline, loading, ready, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var posts: [FeedPost] = []
    private(set) var isLoadingMore = false
    private(set) var reachedEnd = false
    var isMuted = true

    private var cursor: String?
    private var client: FeedClient?
    private let log = Logger(subsystem: "nu.khensu.ptah", category: "feed")

    var isConfigured: Bool { client != nil }

    func start() async {
        client = FeedClient.configured()
        guard client != nil else {
            phase = .offline
            return
        }
        if posts.isEmpty { await refresh() }
    }

    func refresh() async {
        client = FeedClient.configured()
        guard let client else {
            phase = .offline
            posts = []
            return
        }
        if posts.isEmpty { phase = .loading }
        do {
            let page = try await client.feed(before: nil)
            posts = page.posts
            cursor = page.next
            reachedEnd = page.next == nil
            phase = .ready
        } catch {
            log.error("feed: \(error.localizedDescription, privacy: .public)")
            phase = (error as? FeedError) == .offline ? .offline : .failed(error.localizedDescription)
        }
    }

    /// Called as pages scroll into view; fetches the next page a few posts early.
    func didShow(_ post: FeedPost) async {
        guard let i = posts.firstIndex(of: post), i >= posts.count - 4 else { return }
        await loadMore()
    }

    func loadMore() async {
        guard let client, !isLoadingMore, !reachedEnd, let cursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.feed(before: cursor)
            let known = Set(posts.map(\.id))
            posts += page.posts.filter { !known.contains($0.id) }
            self.cursor = page.next
            reachedEnd = page.next == nil || page.posts.isEmpty
        } catch {
            log.error("feed more: \(error.localizedDescription, privacy: .public)")
        }
    }

    func report(_ post: FeedPost, reason: String) async throws {
        guard let client else { throw FeedError.offline }
        try await client.report(postID: post.id, reason: reason)
        posts.removeAll { $0.id == post.id }
    }

    // MARK: Posting

    enum PostStep: Equatable {
        case idle
        case preparing
        case uploadingVideo(Double)
        case uploadingPoster
        case publishing
    }

    private(set) var postStep: PostStep = .idle
    private let tokens = FeedTokens()

    /// Uploads the video and its poster frame, then creates the post.
    func publish(video: URL, handle rawHandle: String, caption: String) async throws {
        guard let client = FeedClient.configured() else { throw FeedError.offline }
        let handle = try Handle.normalize(rawHandle)
        postStep = .preparing
        defer { postStep = .idle }

        let info = try await VideoInfo.load(video)
        let poster = try await VideoInfo.poster(video)
        defer { try? FileManager.default.removeItem(at: poster) }

        let videoType = VideoInfo.contentType(video)
        let videoTicket = try await client.uploadTicket(
            FeedUploadRequest(kind: .video, contentType: videoType, bytes: VideoInfo.size(video)))
        postStep = .uploadingVideo(0)
        try await client.upload(file: video, to: videoTicket, contentType: videoType) { fraction in
            Task { @MainActor [weak self] in
                guard let self, case .uploadingVideo = self.postStep else { return }
                self.postStep = .uploadingVideo(fraction)
            }
        }

        postStep = .uploadingPoster
        let posterTicket = try await client.uploadTicket(
            FeedUploadRequest(kind: .poster, contentType: "image/jpeg", bytes: VideoInfo.size(poster)))
        try await client.upload(file: poster, to: posterTicket, contentType: "image/jpeg") { _ in }

        postStep = .publishing
        let created = try await client.createPost(
            FeedNewPost(handle: handle, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                        videoObject: videoTicket.object, posterObject: posterTicket.object,
                        durationSeconds: info.duration, width: info.width, height: info.height),
            token: tokens.token(for: handle))
        if let token = created.token { try tokens.save(token, for: handle) }
        MyFeedPosts.add(created.post)
        posts.removeAll { $0.id == created.post.id }
        posts.insert(created.post, at: 0)
        phase = .ready
    }
}

/// Duration, display size, poster frame and content type of a picked video.
enum VideoInfo {
    struct Info { var duration: Double; var width: Int; var height: Int }

    static func load(_ url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var width = 0, height = 0
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
            let shown = CGRect(origin: .zero, size: size).applying(transform).size
            width = Int(abs(shown.width).rounded())
            height = Int(abs(shown.height).rounded())
        }
        return Info(duration: duration.isFinite ? duration : 0, width: width, height: height)
    }

    /// A JPEG of the frame at 0.5 s (or the first frame of a shorter clip).
    static func poster(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1080, height: 1920)
        let duration = try await asset.load(.duration).seconds
        let at = CMTime(seconds: min(0.5, max(0, duration.isFinite ? duration / 2 : 0)), preferredTimescale: 600)
        let (image, _) = try await generator.image(at: at)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("poster-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw FeedError.unreadable("poster")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FeedError.unreadable("poster") }
        return out
    }

    static func contentType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov", "qt": "video/quicktime"
        case "m4v": "video/x-m4v"
        default: "video/mp4"
        }
    }

    static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

/// The posts this device published, so Ask khėnsu can search them. They are
/// public already; the list stays in Application Support and is never synced.
enum MyFeedPosts {
    static let maxItems = 200

    private static var url: URL {
        URL.applicationSupportDirectory.appendingPathComponent("khensu/feed-mine.json")
    }

    static func load() -> [FeedPost] {
        (try? JSONDecoder().decode([FeedPost].self, from: Data(contentsOf: url))) ?? []
    }

    static func add(_ post: FeedPost) {
        var items = load().filter { $0.id != post.id }
        items.insert(post, at: 0)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(items.prefix(maxItems))).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            Logger(subsystem: "nu.khensu.ptah", category: "feed").error("my posts: \(error.localizedDescription, privacy: .public)")
        }
    }
}

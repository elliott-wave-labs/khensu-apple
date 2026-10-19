// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A post on the public feed. Public by design: the feed is the open layer,
/// not the encrypted messenger.
public struct FeedPost: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let handle: String
    public let caption: String
    public let videoURL: URL
    public let posterURL: URL?
    public let durationSeconds: Double
    public let width: Int
    public let height: Int
    public let createdAt: Date

    public init(id: String, handle: String, caption: String, videoURL: URL, posterURL: URL?,
                durationSeconds: Double, width: Int, height: Int, createdAt: Date) {
        self.id = id
        self.handle = handle
        self.caption = caption
        self.videoURL = videoURL
        self.posterURL = posterURL
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, handle, caption, width, height
        case videoURL = "video_url"
        case posterURL = "poster_url"
        case durationSeconds = "duration_s"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        handle = try c.decode(String.self, forKey: .handle)
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        videoURL = try c.decode(URL.self, forKey: .videoURL)
        posterURL = try c.decodeIfPresent(String.self, forKey: .posterURL).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        createdAt = try FeedDate.decode(c, forKey: .createdAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(handle, forKey: .handle)
        try c.encode(caption, forKey: .caption)
        try c.encode(videoURL, forKey: .videoURL)
        try c.encodeIfPresent(posterURL, forKey: .posterURL)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(FeedDate.string(createdAt), forKey: .createdAt)
    }

    /// Width over height; 9:16 when the server didn't say.
    public var aspectRatio: Double { width > 0 && height > 0 ? Double(width) / Double(height) : 9.0 / 16.0 }
}

/// `created_at` as an ISO 8601 string (with or without fractional seconds) or Unix seconds.
enum FeedDate {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, forKey key: K) throws -> Date {
        if let seconds = try? c.decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        let s = try c.decode(String.self, forKey: key)
        if let d = try? Date(s, strategy: .iso8601) { return d }
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not an ISO 8601 date: \(s)")
    }

    static func string(_ date: Date) -> String { date.formatted(.iso8601) }
}

public struct FeedPage: Sendable, Decodable, Equatable {
    public let posts: [FeedPost]
    /// Cursor for the next (older) page; nil at the end.
    public let next: String?

    public init(posts: [FeedPost], next: String?) {
        self.posts = posts
        self.next = next
    }
}

public enum FeedUploadKind: String, Sendable, Codable {
    case video, poster
}

public struct FeedUploadRequest: Sendable, Codable, Equatable {
    public let kind: FeedUploadKind
    public let contentType: String
    public let bytes: Int

    public init(kind: FeedUploadKind, contentType: String, bytes: Int) {
        self.kind = kind
        self.contentType = contentType
        self.bytes = bytes
    }

    enum CodingKeys: String, CodingKey {
        case kind, bytes
        case contentType = "content_type"
    }
}

public struct FeedUploadTicket: Sendable, Decodable, Equatable {
    /// Object name to reference in `POST /v1/posts`.
    public let object: String
    /// Signed URL to `PUT` the bytes to, with the same Content-Type.
    public let uploadURL: URL
    public let publicURL: URL

    enum CodingKeys: String, CodingKey {
        case object
        case uploadURL = "upload_url"
        case publicURL = "public_url"
    }
}

public struct FeedNewPost: Sendable, Codable, Equatable {
    public let handle: String
    public let caption: String
    public let videoObject: String
    public let posterObject: String
    public let durationSeconds: Double
    public let width: Int
    public let height: Int

    public init(handle: String, caption: String, videoObject: String, posterObject: String,
                durationSeconds: Double, width: Int, height: Int) {
        self.handle = handle
        self.caption = caption
        self.videoObject = videoObject
        self.posterObject = posterObject
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
    }

    enum CodingKeys: String, CodingKey {
        case handle, caption, width, height
        case videoObject = "video_object"
        case posterObject = "poster_object"
        case durationSeconds = "duration_s"
    }
}

public struct FeedCreated: Sendable, Decodable, Equatable {
    public let post: FeedPost
    /// Issued the first time a handle posts; send it back as a bearer token from then on.
    public let token: String?
}

public enum FeedError: Error, Equatable, Sendable, LocalizedError {
    case offline
    case handleTaken
    case badResponse(Int)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .offline: "The public feed is offline."
        case .handleTaken: "That handle already belongs to someone else on the feed. Choose another."
        case .badResponse(let status): "The feed answered with error \(status)."
        case .unreadable(let why): "The feed sent something unreadable: \(why)"
        }
    }
}

/// Client for the public feed API (`GET /v1/feed`, uploads, posts, reports).
/// Request builders are separate from sending so they can be tested.
public struct FeedClient: Sendable {
    /// UserDefaults key holding the API base URL; empty means the feed is offline.
    public static let defaultsKey = "KhensuFeedAPI"
    public static let pageSize = 20

    public let base: URL
    private let session: URLSession

    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    /// The configured client, or nil when `KhensuFeedAPI` is empty or not a URL.
    public static func configured(_ defaults: UserDefaults = .standard) -> FeedClient? {
        let raw = (defaults.string(forKey: defaultsKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), let scheme = url.scheme, ["https", "http"].contains(scheme), url.host() != nil
        else { return nil }
        return FeedClient(base: url)
    }

    // MARK: Requests

    private func endpoint(_ path: String) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + path)!
    }

    public func feedRequest(before cursor: String?, limit: Int = FeedClient.pageSize) -> URLRequest {
        var components = URLComponents(url: endpoint("/v1/feed"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "before", value: cursor)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func uploadTicketRequest(_ upload: FeedUploadRequest) throws -> URLRequest {
        try jsonRequest("/v1/uploads", body: upload)
    }

    public static func putRequest(_ ticket: FeedUploadTicket, contentType: String) -> URLRequest {
        var request = URLRequest(url: ticket.uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    public func createPostRequest(_ post: FeedNewPost, token: String?) throws -> URLRequest {
        var request = try jsonRequest("/v1/posts", body: post)
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    public func reportRequest(postID: String, reason: String) throws -> URLRequest {
        let id = postID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? postID
        return try jsonRequest("/v1/posts/\(id)/report", body: ["reason": reason])
    }

    private func jsonRequest(_ path: String, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }

    // MARK: Calls

    public func feed(before cursor: String?) async throws -> FeedPage {
        try await decode(FeedPage.self, send(feedRequest(before: cursor)))
    }

    public func uploadTicket(_ upload: FeedUploadRequest) async throws -> FeedUploadTicket {
        try await decode(FeedUploadTicket.self, send(uploadTicketRequest(upload)))
    }

    /// PUTs a file to a signed upload URL, reporting progress from 0 to 1.
    public func upload(file: URL, to ticket: FeedUploadTicket, contentType: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = UploadProgress(progress)
        let (_, response) = try await session.upload(for: Self.putRequest(ticket, contentType: contentType), fromFile: file, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw FeedError.badResponse(status) }
        progress(1)
    }

    public func createPost(_ post: FeedNewPost, token: String?) async throws -> FeedCreated {
        try await decode(FeedCreated.self, send(createPostRequest(post, token: token)))
    }

    public func report(postID: String, reason: String) async throws {
        _ = try await send(reportRequest(postID: postID, reason: reason))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .timedOut, .networkConnectionLost].contains(error.code) {
            throw FeedError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try Self.check(status: status)
        return data
    }

    static func check(status: Int) throws(FeedError) {
        switch status {
        case 200..<300: return
        case 403: throw .handleTaken
        case 502, 503, 504: throw .offline
        default: throw .badResponse(status)
        }
    }

    public func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch {
            throw FeedError.unreadable(String(describing: error))
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

/// Per-handle bearer tokens the feed issues on a handle's first post. Kept in
/// the Keychain (this device only, never synced), not in UserDefaults.
public struct FeedTokens: Sendable {
    private let store: any SecretStore

    public init(store: any SecretStore = KeychainStore(service: "nu.khensu.ptah.feed")) {
        self.store = store
    }

    private func name(_ handle: String) -> String { "feed.token.\(handle.lowercased())" }

    public func token(for handle: String) -> String? {
        (try? store.read(name(handle))).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func save(_ token: String, for handle: String) throws {
        try store.write(name(handle), Data(token.utf8))
    }

    public func forget(_ handle: String) throws {
        try store.delete(name(handle))
    }
}

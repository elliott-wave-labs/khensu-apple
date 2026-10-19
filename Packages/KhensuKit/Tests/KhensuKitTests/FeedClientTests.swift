// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import KhensuKit

@Suite("Public feed client")
struct FeedClientTests {
    private let client = FeedClient(base: URL(string: "https://feed.example/")!)

    private func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test("A feed page decodes posts, ISO dates and the cursor")
    func decodePage() throws {
        let body = Data(#"""
        {"posts":[
          {"id":"p1","handle":"ana","caption":"sunset","video_url":"https://cdn.example/v/p1.mp4",
           "poster_url":"https://cdn.example/p/p1.jpg","duration_s":12.5,"width":1080,"height":1920,
           "created_at":"2026-10-19T18:30:00Z"},
          {"id":"p2","handle":"ben","caption":"","video_url":"https://cdn.example/v/p2.mov",
           "poster_url":null,"duration_s":3,"width":720,"height":1280,
           "created_at":"2026-10-19T18:31:02.250Z"}
        ],"next":"c_42"}
        """#.utf8)
        let page = try client.decode(FeedPage.self, body)
        #expect(page.next == "c_42")
        #expect(page.posts.count == 2)
        let first = page.posts[0]
        #expect(first.id == "p1")
        #expect(first.videoURL.absoluteString == "https://cdn.example/v/p1.mp4")
        #expect(first.posterURL?.lastPathComponent == "p1.jpg")
        #expect(first.durationSeconds == 12.5)
        #expect(first.aspectRatio == 1080.0 / 1920.0)
        #expect(first.createdAt == Date(timeIntervalSince1970: 1_792_434_600))
        #expect(page.posts[1].posterURL == nil)
        #expect(abs(page.posts[1].createdAt.timeIntervalSince(first.createdAt) - 62.25) < 0.001)
    }

    @Test("The last page has a null cursor; Unix timestamps are accepted")
    func decodeLastPage() throws {
        let body = Data(#"{"posts":[{"id":"x","handle":"c","caption":"hi","video_url":"https://a.b/x.mp4","poster_url":"https://a.b/x.jpg","duration_s":1,"width":1,"height":1,"created_at":1792434600}],"next":null}"#.utf8)
        let page = try client.decode(FeedPage.self, body)
        #expect(page.next == nil)
        #expect(page.posts[0].createdAt == Date(timeIntervalSince1970: 1_792_434_600))
    }

    @Test("A malformed page is reported as unreadable")
    func decodeBad() {
        #expect(throws: FeedError.self) { try client.decode(FeedPage.self, Data(#"{"posts":[{"id":1}]}"#.utf8)) }
    }

    @Test("Upload tickets and created posts decode")
    func decodeUploadAndCreated() throws {
        let ticket = try client.decode(FeedUploadTicket.self, Data(#"{"object":"v/abc.mp4","upload_url":"https://s.example/put?sig=1","public_url":"https://cdn.example/v/abc.mp4"}"#.utf8))
        #expect(ticket.object == "v/abc.mp4")
        #expect(ticket.uploadURL.query() == "sig=1")
        let created = try client.decode(FeedCreated.self, Data(#"{"post":{"id":"p9","handle":"ana","caption":"c","video_url":"https://cdn.example/v/abc.mp4","poster_url":"https://cdn.example/p/abc.jpg","duration_s":2,"width":1080,"height":1920,"created_at":"2026-10-19T00:00:00Z"},"token":"t0k"}"#.utf8))
        #expect(created.post.id == "p9")
        #expect(created.token == "t0k")
        let again = try client.decode(FeedCreated.self, Data(#"{"post":{"id":"p10","handle":"ana","caption":"c","video_url":"https://cdn.example/v/x.mp4","poster_url":"https://cdn.example/p/x.jpg","duration_s":2,"width":1,"height":1,"created_at":"2026-10-19T00:00:00Z"}}"#.utf8))
        #expect(again.token == nil)
    }

    @Test("The feed request carries the limit and the cursor")
    func feedRequest() throws {
        let first = client.feedRequest(before: nil)
        #expect(first.httpMethod == "GET")
        #expect(first.url?.absoluteString == "https://feed.example/v1/feed?limit=20")
        let next = client.feedRequest(before: "c 42/x")
        let url = try #require(next.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items == [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "before", value: "c 42/x")])
    }

    @Test("Upload ticket and PUT requests")
    func uploadRequests() throws {
        let request = try client.uploadTicketRequest(FeedUploadRequest(kind: .poster, contentType: "image/jpeg", bytes: 4096))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://feed.example/v1/uploads")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try json(request)
        #expect(body["kind"] as? String == "poster")
        #expect(body["content_type"] as? String == "image/jpeg")
        #expect(body["bytes"] as? Int == 4096)

        let ticket = FeedUploadTicket(object: "v/a", uploadURL: URL(string: "https://s.example/put?sig=1")!, publicURL: URL(string: "https://cdn.example/v/a")!)
        let put = FeedClient.putRequest(ticket, contentType: "video/quicktime")
        #expect(put.httpMethod == "PUT")
        #expect(put.url == ticket.uploadURL)
        #expect(put.value(forHTTPHeaderField: "Content-Type") == "video/quicktime")
    }

    @Test("Creating a post sends snake_case fields and the bearer token when there is one")
    func createRequest() throws {
        let post = FeedNewPost(handle: "ana", caption: "sunset", videoObject: "v/a.mp4", posterObject: "p/a.jpg",
                               durationSeconds: 12.5, width: 1080, height: 1920)
        let anonymous = try client.createPostRequest(post, token: nil)
        #expect(anonymous.url?.absoluteString == "https://feed.example/v1/posts")
        #expect(anonymous.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try json(anonymous)
        #expect(Set(body.keys) == ["handle", "caption", "video_object", "poster_object", "duration_s", "width", "height"])
        #expect(body["video_object"] as? String == "v/a.mp4")
        #expect(body["duration_s"] as? Double == 12.5)
        let signed = try client.createPostRequest(post, token: "t0k")
        #expect(signed.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    }

    @Test("Reports go to the post's report path")
    func reportRequest() throws {
        let request = try client.reportRequest(postID: "p1", reason: "spam")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://feed.example/v1/posts/p1/report")
        #expect(try json(request)["reason"] as? String == "spam")
    }

    @Test("403 means the handle is taken")
    func statuses() {
        #expect(throws: FeedError.handleTaken) { try FeedClient.check(status: 403) }
        #expect(throws: FeedError.badResponse(500)) { try FeedClient.check(status: 500) }
        #expect(throws: FeedError.offline) { try FeedClient.check(status: 503) }
        #expect(throws: Never.self) { try FeedClient.check(status: 201) }
    }

    @Test("An empty or invalid KhensuFeedAPI leaves the feed offline")
    func configuration() throws {
        let defaults = try #require(UserDefaults(suiteName: "feed-tests-\(UUID().uuidString)"))
        #expect(FeedClient.configured(defaults) == nil)
        defaults.set("", forKey: FeedClient.defaultsKey)
        #expect(FeedClient.configured(defaults) == nil)
        defaults.set("not a url", forKey: FeedClient.defaultsKey)
        #expect(FeedClient.configured(defaults) == nil)
        defaults.set("https://feed.example", forKey: FeedClient.defaultsKey)
        #expect(FeedClient.configured(defaults)?.base.absoluteString == "https://feed.example")
    }

    @Test("Tokens are stored per handle")
    func tokens() throws {
        let tokens = FeedTokens(store: MemorySecretStore())
        #expect(tokens.token(for: "ana") == nil)
        try tokens.save("t0k", for: "Ana")
        #expect(tokens.token(for: "ana") == "t0k")
        #expect(tokens.token(for: "ben") == nil)
        try tokens.forget("ana")
        #expect(tokens.token(for: "ana") == nil)
    }
}

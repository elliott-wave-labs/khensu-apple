// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import WebKit
#if os(iOS)
import MediaPlayer
import AVFoundation
#endif

/// Serves `nu-local://media/<persistentID>` audio bytes into the WKWebView so the
/// page can play Music library tracks without uploading them.
final class NuLocalSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "nu-local"

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        #if os(iOS)
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.host == "media", let idString = parts.first, let persistentID = UInt64(idString) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: persistentID),
            forProperty: MPMediaItemPropertyPersistentID
        ))
        guard let item = query.items?.first, let assetURL = item.assetURL else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        Task {
            do {
                let data = try Data(contentsOf: assetURL)
                let mime = Self.mime(for: assetURL) ?? "audio/mpeg"
                let response = URLResponse(
                    url: url,
                    mimeType: mime,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                await MainActor.run {
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
            } catch {
                await MainActor.run {
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
        #else
        urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
        #endif
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    #if os(iOS)
    private static func mime(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "m4a", "mp4", "aac": "audio/mp4"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        case "caf": "audio/x-caf"
        default: nil
        }
    }
    #endif
}

// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import WebKit
#if os(iOS)
import CoreMotion
import MediaPlayer
import AVFoundation
#endif

/// Bridges the waves.khensu.nu page to AirPods head pose and the on-device Music library.
/// Page → native: `webkit.messageHandlers.waves.postMessage({ type, … })`.
/// Native → page: `window.__wavesNative.head(yaw, pitch, roll)` and `.library(items)`.
@MainActor
final class WavesBridge: NSObject, WKScriptMessageHandler {
    static let name = "waves"

    private weak var webView: WKWebView?
    #if os(iOS)
    private let headphoneMotion = CMHeadphoneMotionManager()
    private var headOn = false
    #endif

    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.name else { return }
        let body: [String: Any]
        if let dict = message.body as? [String: Any] {
            body = dict
        } else if let str = message.body as? String,
                  let data = str.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body = dict
        } else {
            return
        }
        let type = body["type"] as? String ?? ""
        switch type {
        case "head":
            let on = body["on"] as? Bool ?? false
            setHeadTracking(on)
        case "library":
            pushLibrary()
        default:
            break
        }
    }

    func setHeadTracking(_ on: Bool) {
        #if os(iOS)
        headOn = on
        if on {
            guard headphoneMotion.isDeviceMotionAvailable else { return }
            headphoneMotion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self, self.headOn, let attitude = motion?.attitude else { return }
                // CMAttitude: yaw right-positive around up, pitch up-positive, roll right-ear-down — matches head.ts.
                self.pushHead(yaw: attitude.yaw, pitch: attitude.pitch, roll: attitude.roll)
            }
        } else {
            headphoneMotion.stopDeviceMotionUpdates()
        }
        #endif
    }

    private func pushHead(yaw: Double, pitch: Double, roll: Double) {
        let js = "window.__wavesNative&&window.__wavesNative.head&&window.__wavesNative.head(\(yaw),\(pitch),\(roll))"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func pushLibrary() {
        #if os(iOS)
        MPMediaLibrary.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.evaluateLibrary([])
                    return
                }
                let query = MPMediaQuery.songs()
                let items = (query.items ?? []).prefix(2_000).compactMap { item -> [String: Any]? in
                    let id = item.persistentID
                    guard id != 0 else { return nil }
                    // DRM / cloud-only tracks have no assetURL; skip so play doesn't 404.
                    guard item.assetURL != nil else { return nil }
                    var row: [String: Any] = [
                        "id": String(id),
                        "title": item.title ?? "Untitled",
                        "dur": item.playbackDuration,
                        "url": "\(NuLocalSchemeHandler.scheme)://media/\(id)",
                    ]
                    if let a = item.artist { row["artist"] = a }
                    if let al = item.albumTitle { row["album"] = al }
                    return row
                }
                self.evaluateLibrary(Array(items))
            }
        }
        #else
        evaluateLibrary([])
        #endif
    }

    private func evaluateLibrary(_ items: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__wavesNative&&window.__wavesNative.library&&window.__wavesNative.library(\(json))"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func tearDown() {
        setHeadTracking(false)
        webView = nil
    }
}

enum WavesAudioSession {
    static func activatePlayback() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
        try? s.setActive(true)
        #endif
    }
}

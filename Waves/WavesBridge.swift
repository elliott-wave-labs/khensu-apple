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
        WavesSharePlayCoordinator.shared.onEventToWeb = { [weak self] json in
            let js = "window.__wavesNative&&window.__wavesNative.shareplay&&window.__wavesNative.shareplay(\(json))"
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
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
        case "translate":
            let text = body["text"] as? String ?? ""
            let id = body["id"] as? String
            Task { await translate(text, id: id) }
        case "caption":
            let urlString = body["url"] as? String
            let id = body["id"] as? String
            Task { await caption(urlString: urlString, id: id) }
        case "shareplay":
            Task { await WavesSharePlayCoordinator.shared.handleWebMessage(body) }
        default:
            break
        }
    }

    /// Page → native: `{ type: "translate", text, id? }` → `__wavesNative.translated(id, text)`.
    private func translate(_ text: String, id: String?) async {
        do {
            let out = try await OnDeviceCaptions.translate(text)
            pushResult(fn: "translated", id: id, text: out, error: nil)
        } catch {
            pushResult(fn: "translated", id: id, text: nil, error: error.localizedDescription)
        }
    }

    /// Page → native: `{ type: "caption", url, id? }` → `__wavesNative.captioned(id, text)`.
    private func caption(urlString: String?, id: String?) async {
        guard let urlString, let url = URL(string: urlString) else {
            pushResult(fn: "captioned", id: id, text: nil, error: "Missing audio URL")
            return
        }
        do {
            let out = try await OnDeviceCaptions.transcribe(fileURL: url)
            pushResult(fn: "captioned", id: id, text: out, error: nil)
        } catch {
            pushResult(fn: "captioned", id: id, text: nil, error: error.localizedDescription)
        }
    }

    private func pushResult(fn: String, id: String?, text: String?, error: String?) {
        let idJS = id.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" } ?? "null"
        let textJS: String
        if let text, let data = try? JSONSerialization.data(withJSONObject: text),
           let s = String(data: data, encoding: .utf8)
        {
            textJS = s
        } else {
            textJS = "null"
        }
        let errJS: String
        if let error, let data = try? JSONSerialization.data(withJSONObject: error),
           let s = String(data: data, encoding: .utf8)
        {
            errJS = s
        } else {
            errJS = "null"
        }
        let js = "window.__wavesNative&&window.__wavesNative.\(fn)&&window.__wavesNative.\(fn)(\(idJS),\(textJS),\(errJS))"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    /// ñü.mobility xyz estimate (metres, bubble axes: x right, y ahead, z up): head motion integrated
    /// with a strong leak, so it reads as leaning and shifting inside the bubble — never as a walked
    /// distance, and it drifts back to the centre on its own. On-device only, like the pose itself.
    private var mobilityVel = (x: 0.0, y: 0.0, z: 0.0)
    private var mobilityPos = (x: 0.0, y: 0.0, z: 0.0)
    private var mobilityLast: TimeInterval = 0

    func setHeadTracking(_ on: Bool) {
        #if os(iOS)
        headOn = on
        if on {
            mobilityVel = (0, 0, 0)
            mobilityPos = (0, 0, 0)
            mobilityLast = 0
            guard headphoneMotion.isDeviceMotionAvailable else { return }
            headphoneMotion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self, self.headOn, let motion else { return }
                // CMAttitude: yaw right-positive around up, pitch up-positive, roll right-ear-down — matches head.ts.
                let at = motion.attitude
                self.pushHead(yaw: at.yaw, pitch: at.pitch, roll: at.roll, place: self.mobilityPlace(motion))
            }
        } else {
            headphoneMotion.stopDeviceMotionUpdates()
        }
        #endif
    }

    #if os(iOS)
    /// Damped double integration of user acceleration, rotated into the bubble frame by the inverse
    /// attitude, clamped to ±1.2 m. A lean estimate for ñü.mobility, not a position fix.
    private func mobilityPlace(_ motion: CMDeviceMotion) -> (x: Double, y: Double, z: Double) {
        let dt = mobilityLast > 0 ? min(0.1, max(0.001, motion.timestamp - mobilityLast)) : 0.016
        mobilityLast = motion.timestamp
        var acc = motion.userAcceleration
        // Rotate device-frame acceleration into the reference (bubble) frame with the attitude quaternion.
        let q = motion.attitude.quaternion
        let v = (x: acc.x, y: acc.y, z: acc.z)
        let u = (x: 2 * (q.y * v.z - q.z * v.y), y: 2 * (q.z * v.x - q.x * v.z), z: 2 * (q.x * v.y - q.y * v.x))
        acc = CMAcceleration(
            x: v.x + q.w * u.x + (q.y * u.z - q.z * u.y),
            y: v.y + q.w * u.y + (q.z * u.x - q.x * u.z),
            z: v.z + q.w * u.z + (q.x * u.y - q.y * u.x))
        // CMAcceleration is in g; to m/s², then integrate with leaks (velocity 0.80, place 0.995 per step at 60 Hz).
        mobilityVel.x = mobilityVel.x * 0.80 + acc.x * 9.81 * dt
        mobilityVel.y = mobilityVel.y * 0.80 + acc.y * 9.81 * dt
        mobilityVel.z = mobilityVel.z * 0.80 + acc.z * 9.81 * dt
        // Bubble axes: reference x right, y ahead (−z of the motion reference), z up.
        mobilityPos.x = clampMobility(mobilityPos.x * 0.995 + mobilityVel.x * dt)
        mobilityPos.y = clampMobility(mobilityPos.y * 0.995 - mobilityVel.z * dt)
        mobilityPos.z = clampMobility(mobilityPos.z * 0.995 + mobilityVel.y * dt)
        return mobilityPos
    }

    private func clampMobility(_ v: Double) -> Double { min(1.2, max(-1.2, v)) }
    #endif

    private func pushHead(yaw: Double, pitch: Double, roll: Double, place: (x: Double, y: Double, z: Double)? = nil) {
        let xyz = place.map { ",\($0.x),\($0.y),\($0.z)" } ?? ""
        let js = "window.__wavesNative&&window.__wavesNative.head&&window.__wavesNative.head(\(yaw),\(pitch),\(roll)\(xyz))"
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

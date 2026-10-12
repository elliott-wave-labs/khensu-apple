// SPDX-License-Identifier: AGPL-3.0-only

import CoreMedia
import Foundation
import ImageIO
import Vision

/// Effects anyone in a call or live room can set off. They're sent to every
/// viewer, guest and cohost, and each device draws them itself.
enum CallEffect: String, Codable, Sendable, CaseIterable {
    /// Two hands in a heart: the heart dissolves in backwards, holds, then explodes.
    case heart
    /// A thumbs up: aura fireworks.
    case spark
}

/// Our own on-device hand gestures, run with Vision's hand pose model on
/// every third camera frame. The system's camera reactions are turned off
/// for the app (`NSCameraReactionEffectGesturesEnabledDefault`), so only
/// these fire. Nothing leaves the device except the effect it triggers.
final class GestureDetector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nu.khensu.call.gestures", qos: .userInitiated)
    private var busy = false
    private var frame = 0
    private var streak: [CallEffect: Int] = [:]
    private var lastFired = Date.distantPast
    private let lock = NSLock()

    /// Effect and where it happened, normalised with the origin at top left.
    var onGesture: (@Sendable (CallEffect, CGPoint) -> Void)?

    func process(_ sample: CMSampleBuffer, mirrored: Bool) {
        let go: Bool = lock.withLock {
            frame += 1
            guard frame % 3 == 0, !busy else { return false }
            busy = true
            return true
        }
        guard go, let image = CMSampleBufferGetImageBuffer(sample) else { return }
        queue.async { [self] in
            defer { lock.withLock { busy = false } }
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 2
            let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up)
            guard (try? handler.perform([request])) != nil else { return }
            let hands = (request.results ?? []).compactMap(Hand.init)
            var found: (CallEffect, CGPoint)?
            if let p = Self.heart(hands) { found = (.heart, p) }
            else if let p = hands.lazy.compactMap(Self.thumbsUp).first { found = (.spark, p) }
            for e in CallEffect.allCases {
                if found?.0 == e { streak[e, default: 0] += 1 } else { streak[e] = 0 }
            }
            guard let (effect, point) = found, streak[effect, default: 0] >= 3,
                  Date().timeIntervalSince(lastFired) > 3 else { return }
            lastFired = Date()
            streak[effect] = 0
            let x = mirrored ? 1 - point.x : point.x
            onGesture?(effect, CGPoint(x: x, y: 1 - point.y))
        }
    }

    struct Hand {
        let thumbTip, indexTip, indexMCP, middleTip, ringTip, littleTip, wrist, middleMCP: CGPoint

        init?(_ o: VNHumanHandPoseObservation) {
            func p(_ j: VNHumanHandPoseObservation.JointName) -> CGPoint? {
                guard let r = try? o.recognizedPoint(j), r.confidence > 0.3 else { return nil }
                return r.location
            }
            guard let t = p(.thumbTip), let i = p(.indexTip), let im = p(.indexMCP), let m = p(.middleTip),
                  let r = p(.ringTip), let l = p(.littleTip), let w = p(.wrist), let mm = p(.middleMCP) else { return nil }
            (thumbTip, indexTip, indexMCP, middleTip, ringTip, littleTip, wrist, middleMCP) = (t, i, im, m, r, l, w, mm)
        }
    }

    private static func d(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

    /// Thumb tips touching at the bottom, index tips touching at the top,
    /// and the knuckles wider apart than the tips: the two lobes of a heart.
    static func heart(_ hands: [Hand]) -> CGPoint? {
        guard hands.count == 2 else { return nil }
        let (a, b) = (hands[0], hands[1])
        let span = max(d(a.wrist, a.middleMCP), d(b.wrist, b.middleMCP), 0.05)
        let thumbs = d(a.thumbTip, b.thumbTip)
        let index = d(a.indexTip, b.indexTip)
        let top = mid(a.indexTip, b.indexTip)
        let bottom = mid(a.thumbTip, b.thumbTip)
        guard thumbs < span * 0.7, index < span * 0.7,
              top.y > bottom.y + span * 0.3,
              d(a.indexMCP, b.indexMCP) > index * 1.4 else { return nil }
        return mid(top, bottom)
    }

    /// Thumb well above every other fingertip, and the other fingers curled
    /// back towards the palm.
    static func thumbsUp(_ h: Hand) -> CGPoint? {
        let span = max(d(h.wrist, h.middleMCP), 0.05)
        let others = [h.indexTip, h.middleTip, h.ringTip, h.littleTip]
        guard others.allSatisfy({ h.thumbTip.y > $0.y + span * 0.6 }),
              others.allSatisfy({ d($0, h.middleMCP) < span * 0.9 }) else { return nil }
        return h.thumbTip
    }
}

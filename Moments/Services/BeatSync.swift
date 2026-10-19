// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import Foundation

/// On-device onset detection for beat sync. Energy envelope over PCM — no cloud.
enum BeatSync {
    struct Plan: Sendable {
        var beats: [TimeInterval]
        var clipDurations: [TimeInterval]
    }

    /// Reads mono float PCM from `audioURL`, finds onsets, and returns one slot length per clip.
    static func plan(audioURL: URL, clipCount: Int, songDuration: TimeInterval? = nil) async throws -> Plan {
        let asset = AVURLAsset(url: audioURL)
        let dur: TimeInterval
        if let songDuration {
            dur = songDuration
        } else {
            dur = try await asset.load(.duration).seconds
        }
        guard clipCount > 0, dur > 0.2 else {
            return Plan(beats: [], clipDurations: Array(repeating: 2.4, count: max(clipCount, 0)))
        }

        let beats = try await detectBeats(asset: asset, duration: dur)
        let usable = beats.isEmpty ? strideBeats(duration: dur, count: max(clipCount + 1, 4)) : beats
        var lengths: [TimeInterval] = []
        lengths.reserveCapacity(clipCount)
        for i in 0..<clipCount {
            let a = usable[min(i, usable.count - 1)]
            let b = i + 1 < usable.count ? usable[i + 1] : min(dur, a + 2.4)
            lengths.append(max(0.35, min(4.0, b - a)))
        }
        return Plan(beats: usable, clipDurations: lengths)
    }

    static func detectBeats(url: URL) async throws -> [TimeInterval] {
        try await plan(audioURL: url, clipCount: 1).beats
    }

    static func retimedClips(_ clips: [MomentClip], to beats: [TimeInterval]) -> [MomentClip] {
        guard !clips.isEmpty else { return clips }
        let lengths: [TimeInterval]
        if beats.count >= 2 {
            lengths = (0..<clips.count).map { i in
                let a = beats[min(i, beats.count - 1)]
                let b = i + 1 < beats.count ? beats[i + 1] : a + 2.4
                return max(0.35, min(4.0, b - a))
            }
        } else {
            lengths = Array(repeating: 2.4, count: clips.count)
        }
        return zip(clips, lengths).map { clip, len in
            var c = clip
            c.outDuration = min(len, clip.isPhoto ? len : max(0.35, clip.duration - clip.inPoint))
            return c
        }
    }

    private static func strideBeats(duration: TimeInterval, count: Int) -> [TimeInterval] {
        guard count > 1 else { return [0] }
        let step = duration / Double(count - 1)
        return (0..<count).map { Double($0) * step }
    }

    private static func detectBeats(asset: AVURLAsset, duration: TimeInterval) async throws -> [TimeInterval] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 22_050,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return [] }

        var energies: [Float] = []
        let hop = 1024
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer(),
                  let block = CMSampleBufferGetDataBuffer(sample) else { break }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            var i = 0
            while i + hop <= data.count {
                var sum: Float = 0
                for j in 0..<hop { sum += abs(data[i + j]) }
                energies.append(sum / Float(hop))
                i += hop
            }
        }

        guard energies.count > 16 else { return [] }
        let sampleRate = 22_050.0
        let secondsPerBin = Double(hop) / sampleRate

        // High-pass the envelope, then pick local peaks above a moving threshold.
        var flux = [Float](repeating: 0, count: energies.count)
        for i in 1..<energies.count {
            let d = energies[i] - energies[i - 1]
            flux[i] = max(0, d)
        }
        let window = 32
        var peaks: [TimeInterval] = [0]
        var i = window
        while i < flux.count - window {
            let slice = flux[(i - window)..<(i + window)]
            let mean = slice.reduce(0, +) / Float(slice.count)
            let thr = mean * 1.6 + 0.002
            if flux[i] > thr, flux[i] >= (slice.max() ?? 0) {
                let t = Double(i) * secondsPerBin
                if t - (peaks.last ?? -1) > 0.22, t < duration - 0.05 {
                    peaks.append(t)
                }
            }
            i += 1
        }
        if peaks.last != duration { peaks.append(duration) }
        return peaks
    }
}

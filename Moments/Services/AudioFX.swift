// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import Foundation

/// Voice effects and voice enhancement, rendered offline on the device with AVAudioEngine.
enum AudioFX {
    enum FXError: Error, LocalizedError {
        case noAudio, failed(String)
        var errorDescription: String? {
            switch self {
            case .noAudio: "That clip has no sound to process."
            case .failed(let s): s
            }
        }
    }

    /// Pulls the audio of a media file into a standalone file.
    static func extract(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw FXError.noAudio }
        let out = MediaImport.mediaDir.appendingPathComponent("audio-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw FXError.noAudio }
        do { try await session.export(to: out, as: .m4a) } catch { throw FXError.failed(error.localizedDescription) }
        return out
    }

    /// Applies a voice effect and/or enhancement (high-pass, presence lift, gate-like expander, gentle compression).
    static func process(_ input: URL, effect: VoiceEffect, enhance: Bool) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try render(input, effect: effect, enhance: enhance)
        }.value
    }

    private static func render(_ input: URL, effect: VoiceEffect, enhance: Bool) throws -> URL {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        var chain: [AVAudioNode] = []
        if enhance {
            let eq = AVAudioUnitEQ(numberOfBands: 4)
            let b = eq.bands
            b[0].filterType = .highPass; b[0].frequency = 90; b[0].bypass = false
            b[1].filterType = .parametric; b[1].frequency = 250; b[1].bandwidth = 1.2; b[1].gain = -3; b[1].bypass = false
            b[2].filterType = .parametric; b[2].frequency = 3200; b[2].bandwidth = 1.0; b[2].gain = 4; b[2].bypass = false
            b[3].filterType = .lowPass; b[3].frequency = 12000; b[3].bypass = false
            chain.append(eq)
            let dyn = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            chain.append(dyn)
            let expander = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            chain.append(expander)
        }
        switch effect {
        case .none: break
        case .deep:
            let p = AVAudioUnitTimePitch(); p.pitch = -500; chain.append(p)
        case .chipmunk:
            let p = AVAudioUnitTimePitch(); p.pitch = 800; chain.append(p)
        case .robot:
            let d = AVAudioUnitDistortion(); d.loadFactoryPreset(.speechCosmicInterference); d.wetDryMix = 60; chain.append(d)
        case .echo:
            let d = AVAudioUnitDelay(); d.delayTime = 0.28; d.feedback = 38; d.wetDryMix = 32; chain.append(d)
        case .hall:
            let r = AVAudioUnitReverb(); r.loadFactoryPreset(.cathedral); r.wetDryMix = 38; chain.append(r)
        case .radio:
            let eq = AVAudioUnitEQ(numberOfBands: 2)
            eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 500; eq.bands[0].bypass = false
            eq.bands[1].filterType = .lowPass; eq.bands[1].frequency = 3500; eq.bands[1].bypass = false
            chain.append(eq)
            let d = AVAudioUnitDistortion(); d.loadFactoryPreset(.speechRadioTower); d.wetDryMix = 30; chain.append(d)
        case .telephone:
            let eq = AVAudioUnitEQ(numberOfBands: 2)
            eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 400; eq.bands[0].bypass = false
            eq.bands[1].filterType = .lowPass; eq.bands[1].frequency = 3000; eq.bands[1].bypass = false
            chain.append(eq)
        case .megaphone:
            let d = AVAudioUnitDistortion(); d.loadFactoryPreset(.multiBrokenSpeaker); d.wetDryMix = 45; chain.append(d)
        case .alien:
            let p = AVAudioUnitTimePitch(); p.pitch = 400; chain.append(p)
            let d = AVAudioUnitDistortion(); d.loadFactoryPreset(.speechAlienChatter); d.wetDryMix = 55; chain.append(d)
        case .whisper:
            let r = AVAudioUnitReverb(); r.loadFactoryPreset(.smallRoom); r.wetDryMix = 25; chain.append(r)
            let eq = AVAudioUnitEQ(numberOfBands: 1)
            eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 300; eq.bands[0].bypass = false
            chain.append(eq)
        }

        chain.forEach { engine.attach($0) }
        var last: AVAudioNode = player
        for node in chain { engine.connect(last, to: node, format: format); last = node }
        engine.connect(last, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.scheduleFile(file, at: nil)
        player.play()

        let out = MediaImport.mediaDir.appendingPathComponent("voice-\(effect.rawValue)-\(UUID().uuidString.prefix(6)).caf")
        let outFile = try AVAudioFile(forWriting: out, settings: engine.manualRenderingFormat.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw FXError.failed("Audio buffer failed.")
        }
        // Tail for reverbs and echoes.
        let total = file.length + AVAudioFramePosition(format.sampleRate * 1.2)
        while engine.manualRenderingSampleTime < total {
            let remaining = total - engine.manualRenderingSampleTime
            let frames = min(AVAudioFrameCount(remaining), buffer.frameCapacity)
            switch try engine.renderOffline(frames, to: buffer) {
            case .success: try outFile.write(from: buffer)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext: continue
            case .error: throw FXError.failed("Audio render failed.")
            @unknown default: throw FXError.failed("Audio render failed.")
            }
        }
        player.stop(); engine.stop()
        return out
    }
}

/// Records a voice-over to the media folder.
@MainActor
@Observable
final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    var isRecording = false
    var elapsed: TimeInterval = 0
    private var timer: Timer?

    func start() async throws {
        let ok = await AVAudioApplication.requestRecordPermission()
        guard ok else { throw AudioFX.FXError.failed("Microphone is off for nu.moments. Turn it on in Settings to record a voice-over.") }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        let url = MediaImport.mediaDir.appendingPathComponent("voiceover-\(UUID().uuidString.prefix(8)).m4a")
        let r = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                         AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
        r.record()
        recorder = r
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.recorder?.currentTime ?? 0 }
        }
    }

    func stop() -> URL? {
        timer?.invalidate(); timer = nil
        let url = recorder?.url
        recorder?.stop(); recorder = nil
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        #endif
        return url
    }
}

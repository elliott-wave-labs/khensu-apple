// SPDX-License-Identifier: AGPL-3.0-only

@preconcurrency import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: Camera

/// Front camera at 720p. Frames go to the encoder and the gesture detector;
/// the preview layer shows them mirrored, the way people expect a selfie.
final class CallCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "nu.khensu.call.camera", qos: .userInteractive)
    private var input: AVCaptureDeviceInput?
    private(set) var front = true

    var onFrame: (@Sendable (CMSampleBuffer) -> Void)?

    func start() {
        queue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            attach(front: front)
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
            orient()
            session.commitConfiguration()
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in session.stopRunning() }
    }

    func flip() {
        queue.async { [self] in
            front.toggle()
            session.beginConfiguration()
            attach(front: front)
            orient()
            session.commitConfiguration()
        }
    }

    private func attach(front: Bool) {
        if let input { session.removeInput(input) }
        #if os(iOS)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)
        #else
        let device = AVCaptureDevice.default(for: .video)
        #endif
        guard let device, let new = try? AVCaptureDeviceInput(device: device), session.canAddInput(new) else { return }
        session.addInput(new)
        input = new
        if let range = device.activeFormat.videoSupportedFrameRateRanges.first, range.maxFrameRate >= 30 {
            try? device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }
    }

    private func orient() {
        #if os(iOS)
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
        #endif
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}

// MARK: Video encoder

/// HEVC in real time. The bitrate follows the adaptive ladder; parameter sets
/// go out ahead of every keyframe so a viewer can join at any keyframe.
final class CallVideoEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private var size: (Int32, Int32) = (0, 0)
    private let lock = NSLock()
    private var bitrate = 1_200_000
    private var forceKey = true

    /// (isKeyframe, pts in microseconds, AVCC data, parameter sets on keyframes)
    var onEncoded: (@Sendable (Bool, Int64, Data, [Data]?) -> Void)?

    func setBitrate(_ bps: Int) {
        lock.withLock { bitrate = bps }
        if let session { apply(bps, to: session) }
    }

    func requestKeyframe() { lock.withLock { forceKey = true } }

    func encode(_ sample: CMSampleBuffer) {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
        let w = Int32(CVPixelBufferGetWidth(image))
        let h = Int32(CVPixelBufferGetHeight(image))
        if session == nil || size != (w, h) { makeSession(w, h) }
        guard let session else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let key = lock.withLock { () -> Bool in
            defer { forceKey = false }
            return forceKey
        }
        let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, buffer in
            guard status == noErr, let buffer, let self else { return }
            self.emit(buffer)
        }
    }

    func stop() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    private func makeSession(_ w: Int32, _ h: Int32) {
        stop()
        size = (w, h)
        var s: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: w, height: h, codecType: kCMVideoCodecType_HEVC,
                                   encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard let s else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        apply(lock.withLock { bitrate }, to: s)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        requestKeyframe()
    }

    private func apply(_ bps: Int, to s: VTCompressionSession) {
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        let limit = [Double(bps) / 8 * 1.5, 1.0] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limit)
    }

    private func emit(_ buffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return }
        let data = Data(bytes: pointer, count: length)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var sets: [Data]?
        if key, let format = CMSampleBufferGetFormatDescription(buffer) {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            sets = (0..<count).compactMap { i in
                var p: UnsafePointer<UInt8>?
                var n = 0
                guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                         parameterSetSizeOut: &n, parameterSetCountOut: nil,
                                                                         nalUnitHeaderLengthOut: nil) == noErr, let p else { return nil }
                return Data(bytes: p, count: n)
            }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        onEncoded?(key, Int64(CMTimeGetSeconds(pts) * 1_000_000), data, sets)
    }
}

// MARK: Video sink

/// Rebuilds sample buffers from the wire and hands them to a display layer,
/// which decodes them in hardware.
final class CallVideoSink: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var waitingForKey = true
    private let lock = NSLock()

    /// Called when the picture can't be decoded and a fresh keyframe is needed.
    var onNeedKeyframe: (@Sendable () -> Void)?

    init() {
        layer.videoGravity = .resizeAspectFill
    }

    func setParameterSets(_ sets: [Data]) {
        guard sets.count >= 3 else { return }
        var desc: CMVideoFormatDescription?
        let pointers = sets.map { d -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return UnsafePointer(p)
        }
        defer { pointers.forEach { $0.deallocate() } }
        let sizes = sets.map(\.count)
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                            parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        lock.withLock { format = desc }
    }

    func enqueue(key: Bool, pts: Int64, data: Data) {
        let fmt: CMVideoFormatDescription? = lock.withLock {
            if waitingForKey && !key { return nil }
            if key { waitingForKey = false }
            return format
        }
        guard let fmt else { return }
        var block: CMBlockBuffer?
        let count = data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        DispatchQueue.main.async { [self] in
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
                lock.withLock { waitingForKey = true }
                onNeedKeyframe?()
                return
            }
            renderer.enqueue(sample)
        }
    }
}

// MARK: Audio

/// Voice-processed microphone in, Opus out at the ladder's bitrate; Opus in,
/// one player per remote person out. 20 ms packets at 48 kHz.
final class CallAudio: @unchecked Sendable {
    static let rate = 48_000.0
    static let frames: AVAudioFrameCount = 960

    private let engine = AVAudioEngine()
    private let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private let opus: AVAudioFormat
    private var encoder: AVAudioConverter?
    private var resampler: AVAudioConverter?
    private var players: [String: (AVAudioPlayerNode, AVAudioConverter)] = [:]
    private var scheduled: [String: Int] = [:]
    private var pendingPCM: [Float] = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "nu.khensu.call.audio", qos: .userInteractive)
    private var started = Date()
    var muted = false

    var onPacket: (@Sendable (Int64, Data) -> Void)?

    init() {
        var d = AudioStreamBasicDescription(mSampleRate: Self.rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                            mBytesPerPacket: 0, mFramesPerPacket: Self.frames, mBytesPerFrame: 0,
                                            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        opus = AVAudioFormat(streamDescription: &d)!
    }

    func start(capture: Bool) {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: capture ? .videoChat : .moviePlayback,
                           options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        try? s.setPreferredSampleRate(Self.rate)
        try? s.setPreferredIOBufferDuration(0.01)
        try? s.setActive(true)
        #endif
        started = Date()
        if capture {
            let input = engine.inputNode
            try? input.setVoiceProcessingEnabled(true)
            let format = input.outputFormat(forBus: 0)
            resampler = AVAudioConverter(from: format, to: pcm)
            encoder = AVAudioConverter(from: pcm, to: opus)
            // Constant bitrate within each ladder step, so packet sizes don't follow speech (nu-audio.md, A1).
            encoder?.bitRateStrategy = AVAudioBitRateStrategy_Constant
            encoder?.bitRate = 32_000
            input.installTap(onBus: 0, bufferSize: 480, format: format) { [weak self] buffer, _ in
                self?.queue.async { self?.captured(buffer) }
            }
        }
        _ = engine.mainMixerNode
        engine.prepare()
        try? engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func setBitrate(_ bps: Int) {
        queue.async { self.encoder?.bitRate = bps }
    }

    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let resampler else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: capacity) else { return }
        var fed = false
        resampler.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        let p = out.floatChannelData![0]
        if muted {
            pendingPCM.append(contentsOf: repeatElement(0, count: Int(out.frameLength)))
        } else {
            pendingPCM.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        }
        while pendingPCM.count >= Int(Self.frames) { encodeOne() }
    }

    private func encodeOne() {
        guard let encoder, let frame = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: Self.frames) else { return }
        frame.frameLength = Self.frames
        pendingPCM.withUnsafeBufferPointer { src in
            frame.floatChannelData![0].update(from: src.baseAddress!, count: Int(Self.frames))
        }
        pendingPCM.removeFirst(Int(Self.frames))
        let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: max(1500, encoder.maximumOutputPacketSize))
        var fed = false
        encoder.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return frame
        }
        guard out.byteLength > 0 else { return }
        let data = Data(bytes: out.data, count: Int(out.byteLength))
        onPacket?(Int64(Date().timeIntervalSince(started) * 1_000_000), data)
    }

    /// Plays one Opus packet from `peer`. If more than a quarter second is
    /// already queued, the packet is skipped so the call stays live.
    func play(_ data: Data, from peer: String) {
        queue.async { [self] in
            if players[peer] == nil {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: pcm)
                guard let dec = AVAudioConverter(from: opus, to: pcm) else { return }
                players[peer] = (node, dec)
                if !engine.isRunning { try? engine.start() }
                node.play()
            }
            guard let (node, dec) = players[peer] else { return }
            if lock.withLock({ scheduled[peer, default: 0] }) > Int(Self.rate / 4) { return }
            let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: data.count)
            data.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
            input.byteLength = UInt32(data.count)
            input.packetCount = 1
            input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
            guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: Self.frames * 2) else { return }
            var fed = false
            dec.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            guard out.frameLength > 0 else { return }
            let n = Int(out.frameLength)
            lock.withLock { scheduled[peer, default: 0] += n }
            node.scheduleBuffer(out) { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.scheduled[peer, default: 0] -= n }
            }
        }
    }

    func remove(peer: String) {
        queue.async { [self] in
            guard let (node, _) = players.removeValue(forKey: peer) else { return }
            node.stop()
            engine.detach(node)
        }
    }
}

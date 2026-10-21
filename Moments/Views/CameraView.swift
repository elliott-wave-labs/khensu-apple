// SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import AVFoundation
import PencilKit
import SwiftUI

/// Records straight into the project: up to 10 minutes, 1080p or 4K, 30 or 60 fps, HDR, torch, zoom, front or back.
@MainActor
@Observable
final class CameraModel: NSObject {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice?
    private var audioIn: AVCaptureDeviceInput?
    var position: AVCaptureDevice.Position = .back
    var uhd = false
    var fps60 = false
    var hdr = true
    var torch = false
    var zoom: CGFloat = 1
    var recording = false
    var elapsed: TimeInterval = 0
    var error: String?
    var finished: ((URL?) -> Void)?
    private var timer: Timer?
    static let maxSeconds: Double = 600

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else { error = "Camera is off for nu.moments. Turn it on in Settings."; return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        configure()
        let s = SessionRef(session: session)
        await Task.detached { s.session.startRunning() }.value
    }

    func stop() {
        let s = SessionRef(session: session)
        Task.detached { s.session.stopRunning() }
    }

    func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.filter { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true }.forEach(session.removeInput)
        session.sessionPreset = uhd ? .hd4K3840x2160 : .hd1920x1080
        guard let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: d), session.canAddInput(input) else { error = "No camera available."; return }
        session.addInput(input)
        device = d
        if audioIn == nil, let mic = AVCaptureDevice.default(for: .audio), let a = try? AVCaptureDeviceInput(device: mic), session.canAddInput(a) {
            session.addInput(a); audioIn = a
        }
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        output.maxRecordedDuration = CMTime(seconds: Self.maxSeconds, preferredTimescale: 600)
        try? d.lockForConfiguration()
        let want = fps60 ? 60.0 : 30.0
        let w: Int32 = uhd ? 3840 : 1920
        if let f = d.formats.first(where: { f in
            CMVideoFormatDescriptionGetDimensions(f.formatDescription).width == w &&
                f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= want } && (!hdr || f.isVideoHDRSupported)
        }) ?? d.formats.first(where: { f in
            CMVideoFormatDescriptionGetDimensions(f.formatDescription).width == w && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= want }
        }) {
            d.activeFormat = f
            d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(want))
            d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(want))
            if f.isVideoHDRSupported { d.automaticallyAdjustsVideoHDREnabled = false; d.isVideoHDREnabled = hdr }
        }
        d.unlockForConfiguration()
        if let c = output.connection(with: .video) {
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = position == .front }
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if output.availableVideoCodecTypes.contains(.hevc) { output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: c) }
        }
        applyZoom(); applyTorch()
    }

    func applyZoom() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        d.videoZoomFactor = min(max(1, zoom), min(10, d.maxAvailableVideoZoomFactor))
        d.unlockForConfiguration()
    }

    func applyTorch() {
        guard let d = device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
        d.torchMode = torch ? .on : .off
        d.unlockForConfiguration()
    }

    func flip() { position = position == .back ? .front : .back; torch = false; reconfigure() }
    func reconfigure() {
        let s = SessionRef(session: session)
        configure()
        if !session.isRunning { Task.detached { s.session.startRunning() } }
    }

    func toggleRecord() {
        if recording { output.stopRecording(); return }
        let url = MediaImport.mediaDir.appendingPathComponent("camera-\(UUID().uuidString.prefix(8)).mov")
        output.startRecording(to: url, recordingDelegate: self)
        recording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self { self.elapsed = self.output.recordedDuration.seconds } }
        }
    }
}

private struct SessionRef: @unchecked Sendable { let session: AVCaptureSession }

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        let ok = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        Task { @MainActor in
            self.timer?.invalidate()
            self.recording = false
            self.finished?(ok ? outputFileURL : nil)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> Preview {
        let v = Preview()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: Preview, context: Context) {}
}

struct CameraView: View {
    let onFinish: (URL?) -> Void
    @State private var cam = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: cam.session).ignoresSafeArea()
                .gesture(MagnifyGesture().onChanged { v in cam.zoom = max(1, min(10, v.magnification)); cam.applyZoom() })
            VStack {
                HStack(spacing: 10) {
                    Button { cam.stop(); onFinish(nil) } label: { Image(systemName: "xmark").padding(10) }
                        .glassEffect(.regular, in: Circle())
                    Spacer()
                    if cam.recording {
                        Text(String(format: "%d:%02d / 10:00", Int(cam.elapsed) / 60, Int(cam.elapsed) % 60))
                            .font(.caption.monospacedDigit().weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                            .glassEffect(.regular.tint(.red.opacity(0.4)), in: Capsule())
                    } else {
                        toggle(cam.uhd ? "4K" : "HD") { cam.uhd.toggle(); cam.reconfigure() }
                        toggle(cam.fps60 ? "60" : "30") { cam.fps60.toggle(); cam.reconfigure() }
                        toggle(cam.hdr ? "HDR" : "SDR") { cam.hdr.toggle(); cam.reconfigure() }
                    }
                    Button { cam.torch.toggle(); cam.applyTorch() } label: { Image(systemName: cam.torch ? "bolt.fill" : "bolt.slash").padding(10) }
                        .glassEffect(.regular, in: Circle())
                }
                .padding(.horizontal, 16)
                Spacer()
                HStack {
                    Text(String(format: "%.1f×", cam.zoom)).font(.caption.monospacedDigit()).frame(width: 60)
                    Spacer()
                    Button { cam.toggleRecord() } label: {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 78, height: 78)
                            RoundedRectangle(cornerRadius: cam.recording ? 8 : 32).fill(.red).frame(width: cam.recording ? 32 : 64, height: cam.recording ? 32 : 64)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { cam.flip() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3).padding(12) }
                        .glassEffect(.regular, in: Circle())
                        .disabled(cam.recording)
                        .frame(width: 60)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .foregroundStyle(.white)
        }
        .task {
            cam.finished = { url in cam.stop(); onFinish(url) }
            await cam.start()
        }
        .alert("Camera", isPresented: Binding(get: { cam.error != nil }, set: { if !$0 { cam.error = nil } })) {
            Button("OK") { onFinish(nil) }
        } message: { Text(cam.error ?? "") }
    }

    private func toggle(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 8) }
            .glassEffect(.regular, in: Capsule())
    }
}

// MARK: - Drawing (PencilKit) saved as a transparent PNG overlay

struct DrawingSheet: View {
    let aspect: CGSize
    let onDone: (URL?) -> Void
    @State private var canvas = PKCanvasView()

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let w = min(geo.size.width, geo.size.height * aspect.width / aspect.height)
                PencilCanvas(canvas: canvas)
                    .frame(width: w, height: w * aspect.height / aspect.width)
                    .background(Color(white: 0.12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Draw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { onDone(save()) } }
            }
        }
    }

    private func save() -> URL? {
        let b = canvas.bounds
        guard !canvas.drawing.strokes.isEmpty, b.width > 0 else { return nil }
        let img = canvas.drawing.image(from: b, scale: aspect.width / b.width)
        guard let png = img.pngData() else { return nil }
        let url = MediaImport.mediaDir.appendingPathComponent("drawing-\(UUID().uuidString.prefix(8)).png")
        try? png.write(to: url)
        return url
    }
}

private struct PencilCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    final class Coordinator { let picker = PKToolPicker() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.tool = PKInkingTool(.marker, color: .white, width: 12)
        context.coordinator.picker.setVisible(true, forFirstResponder: canvas)
        context.coordinator.picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }
    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}
#endif

// SPDX-License-Identifier: AGPL-3.0-only

@preconcurrency import AVFoundation
import StoreKit
import SwiftUI

/// Full-screen call or live room: remote and local video (system PiP keeps
/// both), duration on a Live Activity, controls on translucent fills (glass
/// steps aside over video).
struct CallView: View {
    let session: CallSession
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var systemPiP: CallPiPCoordinator?
    #endif
    @State private var corner = CGSize(width: 1, height: -1)
    @State private var drag = CGSize.zero
    @State private var showTips = false
    @State private var tips = TipStore()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            stage.ignoresSafeArea()
            EffectsLayer(effects: session.effects).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer()
                toasts
                controls
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            if case .ended(let reason) = session.phase {
                ended(reason)
            }
        }
        .videoSurface()
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(session.phase == .connected)
        .persistentSystemOverlays(.hidden)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, session.phase == .connected {
                systemPiP?.start()
            }
        }
        #endif
        .sheet(isPresented: $showTips) { tipSheet }
        .task { session.start() }
        .onDisappear {
            #if os(iOS)
            systemPiP?.stop()
            #endif
            session.end()
        }
    }

    // MARK: Stage

    @ViewBuilder private var stage: some View {
        #if os(iOS)
        ZStack {
            CallPiPStage(session: session, pip: $systemPiP)
            if session.role == .host && session.mode == .live && session.viewerCount == 0 && session.peers.isEmpty {
                liveHostEmpty
            } else if session.phase != .connected || session.peers.first?.cameraOff == true
                || (session.role == .host && session.peers.isEmpty && session.mode != .live) {
                waitingCard(session.peers.first?.name)
            }
        }
        #else
        GeometryReader { geo in
            ZStack {
                if session.role == .host && session.mode == .live {
                    selfView.frame(width: geo.size.width, height: geo.size.height)
                    if session.viewerCount == 0 && session.peers.isEmpty { liveHostEmpty }
                } else {
                    remote
                    if session.isSending { cornerPiP(in: geo.size) }
                }
            }
        }
        #endif
    }

    /// Live host with nobody watching yet: keep the camera up, don’t cover it in black.
    private var liveHostEmpty: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Text("You’re live").font(.title3.weight(.semibold))
                Text("Share the invite from a chat so people can watch and tip you. Gifts stay 100% yours.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                ShareLink(
                    item: CallInvite.text(room: session.roomID, mode: .live),
                    subject: Text("I’m live on khensu.ñü"),
                    message: Text("Join my live room on khensu.ñü")
                ) {
                    Label("Share invite", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(LinearGradient(colors: Aura.glow, startPoint: .leading, endPoint: .trailing), in: .capsule)
                        .foregroundStyle(.black)
                }
            }
            .padding(18)
            .frame(maxWidth: 360)
            .khensuGlass(in: .rect(cornerRadius: 22))
            .padding(.bottom, 110)
        }
        .padding(.horizontal, 20)
        .allowsHitTesting(true)
    }

    #if !os(iOS)
    @ViewBuilder private var remote: some View {
        let other = session.peers.first
        ZStack {
            SampleBufferView(layer: session.pipe.sink.layer)
            if session.phase != .connected || other?.cameraOff == true || (session.role == .host && session.peers.isEmpty) {
                waitingCard(other?.name)
            }
        }
    }

    @ViewBuilder private var selfView: some View {
        if let camera = session.camera {
            CameraPreview(session: camera.session).overlay {
                if session.cameraOff { Color.black.overlay { Image(systemName: "video.slash.fill").font(.largeTitle).foregroundStyle(.secondary) } }
            }
        }
    }

    private func cornerPiP(in size: CGSize) -> some View {
        let w = min(size.width * 0.3, 150)
        let h = w * 16 / 9
        let x = (size.width - w) / 2 - 16
        let y = (size.height - h) / 2 - 110
        return selfView
            .frame(width: w, height: h)
            .clipShape(.rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(AngularGradient(colors: Aura.glow + [Aura.glow[0]], center: .center), lineWidth: 1.5)
                    .opacity(0.8)
            }
            .shadow(color: .black.opacity(0.5), radius: 18)
            .offset(x: corner.width * x + drag.width, y: -corner.height * y + drag.height)
            .gesture(DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { v in
                    withAnimation(.spring(duration: 0.35)) {
                        let px = corner.width * x + v.predictedEndTranslation.width
                        let py = -corner.height * y + v.predictedEndTranslation.height
                        corner = CGSize(width: px < 0 ? -1 : 1, height: py < 0 ? 1 : -1)
                        drag = .zero
                    }
                })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    private func waitingCard(_ name: String?) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(AngularGradient(colors: Aura.glow + [Aura.glow[0]], center: .center)).blur(radius: 30).opacity(0.5)
                Avatar(title: name ?? "khensu", size: 96)
            }
            .frame(width: 140, height: 140)
            Text(waitingText).font(.headline).foregroundStyle(Palette.starlight)
            if session.role == .host && session.phase == .waiting {
                Text("They join from the invitation in your chat.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private var waitingText: String {
        switch session.phase {
        case .waiting: session.mode == .live ? "You’re live" : "Calling…"
        case .connecting: "Connecting…"
        case .connected: session.peers.first?.cameraOff == true ? "Camera off" : "Connected"
        case .ended: "Call ended"
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if session.mode == .live {
                        Text("LIVE").font(.caption.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(LinearGradient(colors: Aura.glow, startPoint: .leading, endPoint: .trailing), in: .capsule)
                            .foregroundStyle(.black)
                        Label("\(session.viewerCount)", systemImage: "eye.fill").font(.caption.weight(.semibold))
                    }
                    Text(title).font(.headline)
                }
                HStack(spacing: 6) {
                    if let start = session.connectedAt {
                        Text(start, style: .timer).monospacedDigit()
                    }
                    if let code = session.safetyCode {
                        Label(code, systemImage: "lock.fill").monospacedDigit()
                            .accessibilityLabel("Safety code \(code). Read it aloud to check nobody is in between.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                #if os(iOS)
                if session.phase == .connected {
                    Button {
                        if systemPiP?.isActive == true { systemPiP?.stop() } else { systemPiP?.start() }
                    } label: {
                        Image(systemName: systemPiP?.isActive == true
                              ? "rectangle.on.rectangle.slash"
                              : "rectangle.on.rectangle")
                            .font(.body.weight(.semibold))
                            .padding(8)
                            .khensuGlass(in: .circle)
                    }
                    .accessibilityLabel(systemPiP?.isActive == true ? "Leave Picture in Picture" : "Picture in Picture")
                }
                #endif
                if session.isSending && session.phase == .connected {
                    Text(rateLabel).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .khensuGlass(in: .capsule)
                }
            }
        }
        .foregroundStyle(Palette.starlight)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.6), radius: 8)
    }

    private var title: String {
        if session.role == .host && session.mode == .live { return session.localName }
        return session.peers.first?.name ?? (session.role == .host ? "Waiting" : "khensu.ñü")
    }

    private var rateLabel: String {
        let a = "ñü.sound \(session.audioRate / 1000) kbit/s"
        return session.videoRate > 0 ? "\(a) · video \(session.videoRate / 1000) kbit/s" : "\(a) · audio only"
    }

    // MARK: Controls

    private var toasts: some View {
        VStack(spacing: 6) {
            ForEach(session.toasts) { t in
                Text(t.text).font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .khensuGlass(in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: session.toasts)
        .padding(.bottom, 10)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if session.isSending {
                round(session.muted ? "mic.slash.fill" : "mic.fill", label: session.muted ? "Unmute" : "Mute", on: session.muted) {
                    session.muted.toggle()
                }
                round(session.cameraOff ? "video.slash.fill" : "video.fill", label: "Camera", on: session.cameraOff) {
                    session.cameraOff.toggle()
                }
                #if os(iOS)
                round("arrow.triangle.2.circlepath.camera.fill", label: "Flip camera") { session.camera?.flip() }
                #endif
                Menu {
                    ForEach(AvatarStyle.allCases) { style in
                        Button {
                            session.avatarStyle = style
                        } label: {
                            Label(style.label, systemImage: style.symbol)
                            if session.avatarStyle == style { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    Image(systemName: session.avatarStyle == .off ? "person.crop.artframe" : session.avatarStyle.symbol)
                        .font(.title3.weight(.semibold))
                        .frame(width: 50, height: 50)
                        .foregroundStyle(session.avatarStyle == .off
                            ? AnyShapeStyle(Palette.starlight)
                            : AnyShapeStyle(LinearGradient(colors: Aura.core, startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .background(.white.opacity(0.12), in: .circle)
                }
                .accessibilityLabel("ñü.ævätåřş style, \(session.avatarStyle.label)")
            }
            round("heart.fill", label: "Send a heart", aura: true) { session.trigger(.heart) }
            round("sparkles", label: "Send fireworks", aura: true) { session.trigger(.spark) }
            // Viewers gift the streamer; tips stay 100% to the person (app commerce).
            if session.role == .viewer || (session.mode == .live && session.role != .host) {
                round("gift.fill", label: "Gift streamer", aura: true) { showTips = true }
            }
            Button {
                session.end()
                dismiss()
            } label: {
                Image(systemName: "phone.down.fill").font(.title3.weight(.semibold))
                    .frame(width: 58, height: 58)
                    .background(.red, in: .circle)
                    .foregroundStyle(.white)
            }
            .accessibilityLabel(session.mode == .live && session.role == .host ? "End live" : "Leave")
        }
        .padding(10)
        .khensuGlass(in: .capsule)
    }

    private func round(_ symbol: String, label: String, on: Bool = false, aura: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 50, height: 50)
                .foregroundStyle(on ? AnyShapeStyle(.black) : aura
                    ? AnyShapeStyle(LinearGradient(colors: Aura.core, startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Palette.starlight))
                .background(on ? Palette.starlight : .white.opacity(0.12), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Tips

    private var tipSheet: some View {
        NavigationStack {
            List {
                Section {
                    if tips.loading && tips.products.isEmpty {
                        HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                    }
                    ForEach(tips.products, id: \.id) { p in
                        Button {
                            Task {
                                if let label = await tips.buy(p) {
                                    session.sendTip(label: label)
                                    showTips = false
                                }
                            }
                        } label: {
                            HStack {
                                Text(p.displayName)
                                Spacer()
                                Text(p.displayPrice).fontWeight(.semibold)
                            }
                        }
                    }
                    if !tips.loading && tips.products.isEmpty {
                        Text("Tips aren’t available yet.").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Paid with Apple in-app purchase. Apple keeps its App Store fee; khensu.ñü takes no cut of the rest.")
                }
                if let e = tips.errorMessage {
                    Text(e).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Tip \(title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { showTips = false } } }
        }
        .presentationDetents([.medium])
        .task { await tips.load() }
    }

    private func ended(_ reason: String?) -> some View {
        VStack(spacing: 16) {
            Text(reason == nil ? (session.mode == .live ? "Live ended" : "Call ended") : "Couldn’t connect").font(.title2.bold())
            if let reason { Text(reason).multilineTextAlignment(.center).foregroundStyle(.secondary) }
            Button("Close") { dismiss() }.buttonStyle(.glassProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.85))
    }
}

// MARK: Video surfaces

#if os(iOS)
final class LayerHostView: UIView {
    var hosted: CALayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let hosted { layer.addSublayer(hosted) }
            setNeedsLayout()
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        hosted?.frame = bounds
    }
}

struct SampleBufferView: UIViewRepresentable {
    let layer: CALayer
    func makeUIView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        v.hosted = layer
        return v
    }
    func updateUIView(_ v: LayerHostView, context: Context) {}
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        v.hosted = l
        return v
    }
    func updateUIView(_ v: LayerHostView, context: Context) {}
}
#else
final class LayerHostView: NSView {
    var hosted: CALayer? {
        didSet {
            wantsLayer = true
            oldValue?.removeFromSuperlayer()
            if let hosted { layer?.addSublayer(hosted) }
            needsLayout = true
        }
    }
    override func layout() {
        super.layout()
        hosted?.frame = bounds
    }
}

struct SampleBufferView: NSViewRepresentable {
    let layer: CALayer
    func makeNSView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        v.hosted = layer
        return v
    }
    func updateNSView(_ v: LayerHostView, context: Context) {}
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        v.hosted = l
        return v
    }
    func updateNSView(_ v: LayerHostView, context: Context) {}
}
#endif

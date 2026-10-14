// SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
@preconcurrency import AVFoundation
@preconcurrency import AVKit
import SwiftUI
import UIKit

/// System Picture in Picture for video calls: remote fills the PiP window,
/// your camera sits in a corner. Uses `AVPictureInPictureVideoCallViewController`
/// so capture can keep running while the app is backgrounded.
@MainActor
final class CallPiPCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    private(set) var controller: AVPictureInPictureController?
    private let stage: CallPiPStageController
    private weak var sourceView: UIView?

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }
    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    init(remoteLayer: AVSampleBufferDisplayLayer, camera: CallCamera?) {
        stage = CallPiPStageController(remoteLayer: remoteLayer, camera: camera)
        super.init()
    }

    func attach(sourceView: UIView) {
        self.sourceView = sourceView
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: stage
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.delegate = self
        controller = pip
    }

    func setCameraOff(_ off: Bool) { stage.setCameraOff(off) }
    func setRemoteCameraOff(_ off: Bool) { stage.setRemoteCameraOff(off) }
    func setPeerName(_ name: String) { stage.setPeerName(name) }
    func setSelfMain(_ on: Bool) { stage.setSelfMain(on) }

    func start() {
        guard let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {}
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {}
}

/// The view that becomes the PiP window: remote video full bleed, local camera
/// in the bottom-trailing corner, both always present so PiP shows “my and
/// remote” together.
final class CallPiPStageController: AVPictureInPictureVideoCallViewController {
    private let remoteHost = LayerHostView()
    private let localHost = LayerHostView()
    private let remotePlaceholder = UILabel()
    private let localPlaceholder = UIImageView(image: UIImage(systemName: "video.slash.fill"))
    private var preview: AVCaptureVideoPreviewLayer?
    private weak var camera: CallCamera?

    private let remoteLayer: AVSampleBufferDisplayLayer
    /// When true (live host), the local camera fills the stage and the corner PiP is hidden.
    private var selfMain = false

    init(remoteLayer: AVSampleBufferDisplayLayer, camera: CallCamera?) {
        self.camera = camera
        self.remoteLayer = remoteLayer
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 9, height: 16)
        remoteHost.hosted = remoteLayer
        if let camera {
            let preview = AVCaptureVideoPreviewLayer(session: camera.session)
            preview.videoGravity = .resizeAspectFill
            self.preview = preview
            localHost.hosted = preview
        }
    }

    func setSelfMain(_ on: Bool) {
        selfMain = on
        guard isViewLoaded else { return }
        if on {
            remoteHost.hosted = preview
            localHost.isHidden = true
        } else {
            remoteHost.hosted = remoteLayer
            localHost.hosted = preview
            localHost.isHidden = camera == nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

        remoteHost.translatesAutoresizingMaskIntoConstraints = false
        localHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(remoteHost)
        view.addSubview(localHost)

        remotePlaceholder.textAlignment = .center
        remotePlaceholder.textColor = .secondaryLabel
        remotePlaceholder.font = .preferredFont(forTextStyle: .headline)
        remotePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        remoteHost.addSubview(remotePlaceholder)

        localPlaceholder.tintColor = .secondaryLabel
        localPlaceholder.contentMode = .scaleAspectFit
        localPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        localPlaceholder.isHidden = true
        localHost.addSubview(localPlaceholder)
        localHost.layer.cornerRadius = 14
        localHost.layer.cornerCurve = .continuous
        localHost.clipsToBounds = true
        localHost.layer.borderWidth = 1.5
        localHost.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor

        NSLayoutConstraint.activate([
            remoteHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            remoteHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            remoteHost.topAnchor.constraint(equalTo: view.topAnchor),
            remoteHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            localHost.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.32),
            localHost.heightAnchor.constraint(equalTo: localHost.widthAnchor, multiplier: 16.0 / 9.0),
            localHost.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            localHost.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),

            remotePlaceholder.centerXAnchor.constraint(equalTo: remoteHost.centerXAnchor),
            remotePlaceholder.centerYAnchor.constraint(equalTo: remoteHost.centerYAnchor),
            remotePlaceholder.leadingAnchor.constraint(greaterThanOrEqualTo: remoteHost.leadingAnchor, constant: 12),
            remotePlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: remoteHost.trailingAnchor, constant: -12),

            localPlaceholder.centerXAnchor.constraint(equalTo: localHost.centerXAnchor),
            localPlaceholder.centerYAnchor.constraint(equalTo: localHost.centerYAnchor),
            localPlaceholder.widthAnchor.constraint(equalToConstant: 28),
            localPlaceholder.heightAnchor.constraint(equalToConstant: 28),
        ])
        localHost.isHidden = camera == nil
    }

    func setCameraOff(_ off: Bool) {
        preview?.isHidden = off
        localPlaceholder.isHidden = !off
        localHost.backgroundColor = off ? .black : .clear
    }

    func setRemoteCameraOff(_ off: Bool) {
        remotePlaceholder.isHidden = !off
        remotePlaceholder.text = off ? "Camera off" : nil
    }

    func setPeerName(_ name: String) {
        if remotePlaceholder.text == nil || remotePlaceholder.text == "Camera off" || remotePlaceholder.text?.isEmpty == false {
            if remotePlaceholder.isHidden == false && remotePlaceholder.text != "Camera off" {
                remotePlaceholder.text = name
            }
        }
    }
}

/// Embeds the PiP stage in SwiftUI and wires automatic / manual PiP.
struct CallPiPStage: UIViewControllerRepresentable {
    let session: CallSession
    @Binding var pip: CallPiPCoordinator?

    func makeUIViewController(context: Context) -> CallPiPContainerController {
        let remote = session.pipe.sink.layer
        let coordinator = CallPiPCoordinator(remoteLayer: remote, camera: session.camera)
        let container = CallPiPContainerController(stage: coordinator.stageView)
        DispatchQueue.main.async {
            pip = coordinator
            coordinator.attach(sourceView: container.view)
            coordinator.setSelfMain(session.role == .host && session.mode == .live)
            coordinator.setCameraOff(session.cameraOff)
            coordinator.setRemoteCameraOff(session.peers.first?.cameraOff ?? false)
            coordinator.setPeerName(session.peers.first?.name ?? session.localName)
        }
        return container
    }

    func updateUIViewController(_ controller: CallPiPContainerController, context: Context) {
        pip?.setSelfMain(session.role == .host && session.mode == .live)
        pip?.setCameraOff(session.cameraOff)
        pip?.setRemoteCameraOff(session.peers.first?.cameraOff ?? false)
        pip?.setPeerName(session.peers.first?.name ?? session.localName)
    }
}

extension CallPiPCoordinator {
    fileprivate var stageView: CallPiPStageController { stage }
}

/// Hosts the stage full-screen inside the call UI (the active video-call source view).
final class CallPiPContainerController: UIViewController {
    private let stage: CallPiPStageController

    init(stage: CallPiPStageController) {
        self.stage = stage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(stage)
        stage.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stage.view)
        NSLayoutConstraint.activate([
            stage.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.view.topAnchor.constraint(equalTo: view.topAnchor),
            stage.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        stage.didMove(toParent: self)
    }
}
#endif

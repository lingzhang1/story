import SwiftUI
import AVFoundation
import UIKit
import CoreImage

// Scene Scan live capture (Milestone C2). Mirrors CameraCaptureView's
// AVFoundation + UIViewControllerRepresentable pattern, but GRABS frames
// via AVCaptureVideoDataOutput instead of recording a movie file.
//
// Frames are collected IN MEMORY only — nothing is written to disk here
// (ephemeral inference inputs, never Moments/Assets). The caller receives
// the candidate UIImages via `onFrames` and is responsible for selection,
// upload, and cleanup. Requires a physical device (no camera in Simulator).

struct SceneScanView: UIViewControllerRepresentable {
    /// Called with the collected candidate frames when a scan finishes.
    var onFrames: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> SceneScanController {
        let controller = SceneScanController()
        controller.onFrames = onFrames
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ controller: SceneScanController, context: Context) {}
}

final class SceneScanController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrames: (([UIImage]) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "com.story.scenescan.samples")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private lazy var scanButton = UIButton(type: .system)

    private let ciContext = CIContext()

    // Scanning state (mutated on sampleQueue + main; guarded by `scanning`).
    private var scanning = false
    private var scanStart: CMTime?
    private var lastKeptPTS: CMTime?
    private var candidates: [UIImage] = []

    private let scanDuration: Double = 4.0        // auto-stop after ~4s
    private let frameInterval: Double = 0.35       // throttle ~1 frame / 0.35s

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        configureUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task.detached { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        if let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back),
           let videoInput = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }
        // NO audio input — Scene Scan grabs still frames only.

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview
    }

    private func configureUI() {
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        scanButton.setTitle("Scan", for: .normal)
        scanButton.setTitleColor(.white, for: .normal)
        scanButton.titleLabel?.font = .boldSystemFont(ofSize: 20)
        scanButton.backgroundColor = UIColor(red: 0.83, green: 0.66, blue: 0.33, alpha: 1)
        scanButton.layer.cornerRadius = 28
        scanButton.addTarget(self, action: #selector(toggleScan), for: .touchUpInside)
        view.addSubview(scanButton)

        let cancel = UIButton(type: .system)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.setTitle("Cancel", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            scanButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            scanButton.widthAnchor.constraint(equalToConstant: 140),
            scanButton.heightAnchor.constraint(equalToConstant: 56),
            cancel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
    }

    @objc private func toggleScan() {
        if scanning {
            finishScan()
        } else {
            startScan()
        }
    }

    @objc private func cancelTapped() {
        sampleQueue.async { [weak self] in self?.resetScanState() }
        onCancel?()
    }

    private func startScan() {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            self.candidates.removeAll()
            self.scanStart = nil
            self.lastKeptPTS = nil
            self.scanning = true
        }
        scanButton.setTitle("Stop", for: .normal)
        scanButton.backgroundColor = .systemRed
    }

    /// Collects the candidates captured so far and hands them to the caller.
    private func finishScan() {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            guard self.scanning else { return }
            self.scanning = false
            let frames = self.candidates
            self.candidates.removeAll()
            self.scanStart = nil
            self.lastKeptPTS = nil
            DispatchQueue.main.async {
                self.scanButton.setTitle("Scan", for: .normal)
                self.scanButton.backgroundColor = UIColor(red: 0.83, green: 0.66, blue: 0.33, alpha: 1)
                self.onFrames?(frames)
            }
        }
    }

    private func resetScanState() {
        scanning = false
        candidates.removeAll()
        scanStart = nil
        lastKeptPTS = nil
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard scanning else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if scanStart == nil { scanStart = pts }

        // Throttle to ~1 frame / frameInterval via presentation timestamp.
        if let last = lastKeptPTS {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, last))
            if delta < frameInterval { return }
        }
        lastKeptPTS = pts

        if let image = Self.image(from: sampleBuffer, context: ciContext) {
            candidates.append(image)
        }

        // Auto-stop after ~scanDuration seconds of captured span.
        if let start = scanStart {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, start))
            if elapsed >= scanDuration {
                finishScan()
            }
        }
    }

    // CMSampleBuffer -> CVPixelBuffer -> CIImage -> CGImage -> UIImage.
    private static func image(from sampleBuffer: CMSampleBuffer,
                              context: CIContext) -> UIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

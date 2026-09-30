import SwiftUI
import AVFoundation
import UIKit

// Real iPhone camera video capture via AVFoundation, exposed to SwiftUI
// as a UIViewControllerRepresentable. Records to a temp file; the caller
// adopts it into MediaStore. Camera hardware is unavailable in the
// Simulator — this path requires a physical device (spec Part 4).
//
// UI depends on this Media module rather than calling AVFoundation
// directly (spec 03 §8).

struct CameraCaptureView: UIViewControllerRepresentable {
    /// Called with the temp file URL + measured duration when a clip finishes.
    var onFinish: (URL, Double) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CameraCaptureController {
        let controller = CameraCaptureController()
        controller.onFinish = onFinish
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ controller: CameraCaptureController, context: Context) {}
}

final class CameraCaptureController: UIViewController, AVCaptureFileOutputRecordingDelegate {
    var onFinish: ((URL, Double) -> Void)?
    var onCancel: (() -> Void)?

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private lazy var recordButton = UIButton(type: .system)
    private var isRecording = false

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

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        if let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back),
           let videoInput = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview
    }

    private func configureUI() {
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.setTitle("Record", for: .normal)
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.titleLabel?.font = .boldSystemFont(ofSize: 20)
        recordButton.backgroundColor = UIColor(red: 0.83, green: 0.66, blue: 0.33, alpha: 1)
        recordButton.layer.cornerRadius = 28
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        view.addSubview(recordButton)

        let cancel = UIButton(type: .system)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.setTitle("Cancel", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            recordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            recordButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            recordButton.widthAnchor.constraint(equalToConstant: 140),
            recordButton.heightAnchor.constraint(equalToConstant: 56),
            cancel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    @objc private func toggleRecording() {
        if isRecording {
            movieOutput.stopRecording()
        } else {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            movieOutput.startRecording(to: tempURL, recordingDelegate: self)
            isRecording = true
            recordButton.setTitle("Stop", for: .normal)
            recordButton.backgroundColor = .systemRed
        }
    }

    @objc private func cancelTapped() { onCancel?() }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        isRecording = false
        recordButton.setTitle("Record", for: .normal)
        let asset = AVURLAsset(url: outputFileURL)
        let duration = CMTimeGetSeconds(asset.duration)
        onFinish?(outputFileURL, duration.isFinite ? duration : 0)
    }
}

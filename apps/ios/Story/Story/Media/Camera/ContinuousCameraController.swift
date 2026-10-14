import UIKit
import AVFoundation
import CoreImage

// ContinuousCameraController — the SHARED AVFoundation capture engine for
// Capture Anywhere (Figma MVP V0.2.2). Unlike the one-shot CameraCaptureView,
// this stays alive across many recordings: the owner (ContinuousCaptureView)
// drives start/stop and persists each finished clip as one independent Moment,
// then the camera remains ready for the next recording. No post-capture page.
//
// Integrity guards live HERE so every caller (Home standalone + in-Story) gets
// the same protection (one engine, one set of rules):
//   • Rapid taps / double callbacks — a strict state machine (.idle → .starting
//     → .recording → .stopping) rejects out-of-phase taps; the AV delegate
//     callback is dispatched exactly once per recording via a token.
//   • Backgrounding / interruptions — AVCaptureSession interruption + app
//     lifecycle notifications stop an in-flight recording cleanly (the partial
//     clip is still delivered so nothing silently vanishes).
//   • Storage/engine errors — a failed start or a delegate error surfaces as
//     .captureFailed; no false "saved" state is ever produced.
//   • Orphaned temp files — each recording writes to a uniquely-named temp
//     file; the controller tracks the active URL so a cancelled/failed clip
//     can be removed. Temp files live in the system temp dir and are reclaimed
//     by the OS; the controller deletes on explicit failure.
//
// The controller NEVER persists — it only produces (tempURL, duration) and
// lifecycle events. Persistence + Moment creation is the owner's job, so the
// single CaptureContext-driven persistence path is reused unchanged.

enum ContinuousCaptureEvent {
    case ready                       // session running, safe to record
    case recordingStarted
    case recordingFinished(URL, Double)
    case captureFailed(String)       // human-readable, non-semantic
    case interrupted                 // session interrupted (phone call, etc.)
}

protocol ContinuousCameraControllerDelegate: AnyObject {
    func captureEvent(_ event: ContinuousCaptureEvent)
}

final class ContinuousCameraController: UIViewController, AVCaptureFileOutputRecordingDelegate,
                                        AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var delegate: ContinuousCameraControllerDelegate?

    // Strict phase machine — the single source of truth for "can I tap now?".
    private enum Phase { case idle, starting, recording, stopping }
    private var phase: Phase = .idle

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    // Scene-scan frame grabbing — a SECOND output on the SAME session so an AI
    // scan can collect frames WITHOUT a separate camera session and WITHOUT
    // interrupting an in-flight recording (Figma: "you can keep recording").
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let scanQueue = DispatchQueue(label: "com.story.continuous.scan")
    private let ciContext = CIContext()
    private var scanning = false
    private var scanStart: CMTime?
    private var lastKeptPTS: CMTime?
    private var scanFrames: [UIImage] = []
    private var scanCompletion: (([UIImage]) -> Void)?
    private var scanProgress: ((Double) -> Void)?     // 0→1 over the scan window (for the UI progress bar)
    private let scanDuration: Double = 4.0
    private let scanFrameInterval: Double = 0.35

    // The temp URL of the active recording + a token to ensure the AV finish
    // callback is honored exactly once (guards against double delegate calls).
    private var activeTempURL: URL?
    private var activeToken: UUID?
    private var recordingStart: Date?

    /// Whether a recording is currently in progress (owner reads this to render
    /// the record vs stop button and to gate overlay actions).
    var isRecording: Bool { phase == .recording }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        observeLifecycle()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // If we are leaving mid-recording, stop cleanly so the partial clip is
        // delivered rather than lost (the owner decides whether to keep it).
        if phase == .recording { movieOutput.stopRecording() }
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func startSession() {
        Task.detached { [session] in
            if !session.isRunning { session.startRunning() }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.phase == .idle { self.delegate?.captureEvent(.ready) }
            }
        }
    }

    // MARK: - Session configuration

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
        // Second output on the SAME session for AI scan frame grabbing. Frames are
        // collected in memory only during an explicit scan; the delegate ignores
        // buffers unless `scanning` is true, so there is no steady-state cost.
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: scanQueue)
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
        }
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview
    }

    // MARK: - Interruption / backgrounding guards

    private func observeLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionInterrupted),
                       name: .AVCaptureSessionWasInterrupted, object: session)
        nc.addObserver(self, selector: #selector(appResignActive),
                       name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func sessionInterrupted() {
        if phase == .recording {
            // Deliver the partial clip then report the interruption so the owner
            // can show an honest state (never a false success).
            movieOutput.stopRecording()
        }
        delegate?.captureEvent(.interrupted)
    }

    @objc private func appResignActive() {
        // Backgrounding mid-recording: finalize what we have rather than drop it.
        if phase == .recording { movieOutput.stopRecording() }
    }

    // MARK: - Record / stop (driven by the owner's red button)

    /// Toggle entry point used by the owner's single record/stop button.
    func toggleRecording() {
        switch phase {
        case .idle:      beginRecording()
        case .recording: endRecording()
        case .starting, .stopping: break    // in-flight — reject the tap (rapid-tap guard)
        }
    }

    private func beginRecording() {
        guard phase == .idle, session.isRunning else { return }
        phase = .starting
        let token = UUID()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cap-\(token.uuidString)")
            .appendingPathExtension("mov")
        activeTempURL = tempURL
        activeToken = token
        recordingStart = Date()
        movieOutput.startRecording(to: tempURL, recordingDelegate: self)
        // AVCaptureMovieFileOutput confirms the actual start via
        // didStartRecordingTo; flip to .recording there so the button can't be
        // tapped to "stop" a recording that has not physically begun.
    }

    private func endRecording() {
        guard phase == .recording else { return }
        phase = .stopping
        movieOutput.stopRecording()
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        // Physical start confirmed.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase == .starting else { return }
            self.phase = .recording
            self.delegate?.captureEvent(.recordingStarted)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Exactly-once: ignore a callback that does not correspond to the
            // active recording (double-callback guard).
            guard self.activeToken != nil, self.phase == .stopping || self.phase == .recording
            else { return }
            self.phase = .idle
            self.activeToken = nil
            let started = self.recordingStart ?? Date()
            self.recordingStart = nil

            if let error = error as NSError? {
                // AVErrorRecordingSuccessfullyFinished means the stop was clean
                // despite a non-nil error (e.g. interruption) — treat the clip as
                // valid. maximumDurationReached is likewise a clean finish.
                let successfullyFinished =
                    (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true
                let recoverable = error.code == AVError.Code.maximumDurationReached.rawValue
                if !successfullyFinished && !recoverable {
                    self.cleanupTempFile()
                    self.delegate?.captureEvent(.captureFailed(self.friendly(error)))
                    return
                }
            }

            // Validate the file actually exists before claiming a clip.
            guard FileManager.default.fileExists(atPath: outputFileURL.path) else {
                self.cleanupTempFile()
                self.delegate?.captureEvent(.captureFailed("The recording could not be saved."))
                return
            }
            let asset = AVURLAsset(url: outputFileURL)
            let dur = CMTimeGetSeconds(asset.duration)
            let duration = (dur.isFinite && dur > 0) ? dur : Date().timeIntervalSince(started)
            self.activeTempURL = nil   // ownership handed to the owner for adoption
            self.delegate?.captureEvent(.recordingFinished(outputFileURL, duration))
        }
    }

    // MARK: - Scene scan (AI Ideas) — concurrent with recording

    /// Collect ~scanDuration seconds of throttled frames from the live session and
    /// deliver them to `completion`. Does NOT touch recording — the user can keep
    /// recording during a scan. Calling again while scanning restarts the window.
    func startScan(completion: @escaping ([UIImage]) -> Void) {
        scanQueue.async { [weak self] in
            guard let self else { return }
            self.scanFrames.removeAll()
            self.scanStart = nil
            self.lastKeptPTS = nil
            self.scanCompletion = completion
            self.scanning = true
        }
    }

    /// Collect ~scanDuration seconds of throttled frames from the live session and
    /// deliver them to `completion`. Does NOT touch recording — the user can keep
    /// recording during a scan. Calling again while scanning restarts the window.
    /// `progress` is fired 0→1 across the scan window so the UI can show a determinate bar.
    func startScan(progress: ((Double) -> Void)? = nil, completion: @escaping ([UIImage]) -> Void) {
        scanQueue.async { [weak self] in
            guard let self else { return }
            self.scanFrames.removeAll()
            self.scanStart = nil
            self.lastKeptPTS = nil
            self.scanCompletion = completion
            self.scanProgress = progress
            self.scanning = true
        }
    }

    /// The fixed scan window length (seconds), so the owner can label/scale the progress UI.
    var scanWindowSeconds: Double { scanDuration }

    /// Proactively END the current scan NOW and deliver whatever frames were collected
    /// (user tapped "Done" before the window elapsed). Safe if ≥1 frame; otherwise reports empty.
    func finishScanNow() {
        scanQueue.async { [weak self] in self?.finishScan() }
    }

    /// Abort an in-flight scan without delivering frames (user tapped Cancel scan).
    func cancelScan() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            self.scanning = false
            self.scanFrames.removeAll()
            self.scanStart = nil
            self.lastKeptPTS = nil
            self.scanCompletion = nil
            self.scanProgress = nil
        }
    }

    private func finishScan() {
        // Called on scanQueue.
        guard scanning else { return }
        scanning = false
        let frames = scanFrames
        let completion = scanCompletion
        scanFrames.removeAll()
        scanStart = nil
        lastKeptPTS = nil
        scanCompletion = nil
        scanProgress = nil
        DispatchQueue.main.async { completion?(frames) }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard scanning else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if scanStart == nil { scanStart = pts }
        if let last = lastKeptPTS {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, last))
            if delta < scanFrameInterval { return }
        }
        lastKeptPTS = pts
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            if let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                scanFrames.append(UIImage(cgImage: cg))
            }
        }
        if let start = scanStart {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, start))
            let p = max(0, min(1, elapsed / scanDuration))
            if let cb = scanProgress { DispatchQueue.main.async { cb(p) } }
            if elapsed >= scanDuration { finishScan() }
        }
    }

    // MARK: - Helpers

    /// Remove the active temp file (used when a recording failed and will not be adopted).
    func cleanupTempFile() {
        if let url = activeTempURL { try? FileManager.default.removeItem(at: url) }
        activeTempURL = nil
    }

    private func friendly(_ error: NSError) -> String {
        if error.code == AVError.Code.diskFull.rawValue { return "Your device is out of storage." }
        return "The recording stopped unexpectedly."
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

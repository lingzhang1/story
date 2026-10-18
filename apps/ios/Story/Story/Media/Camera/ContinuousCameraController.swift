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
    case presetsReady([Double])      // device-derived zoom presets available (strip can render)
    case zoomChanged(Double)         // live USER-× zoom factor (pinch/preset) for the strip
    case aeafLockChanged(Bool)       // AE/AF lock engaged/released (Increment 2)
    case cameraPositionChanged(Bool) // true = front camera now active (Increment 2)
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

    // Package B Increment 1 — camera controls (ADDITIVE; the recording engine is unchanged).
    // The back-camera device + its input are retained so focus/exposure/zoom/torch can be
    // configured on it. All device configuration is serialized on `sessionQueue` and wrapped in
    // lockForConfiguration, so it can never interleave with the recording state machine on main.
    private let sessionQueue = DispatchQueue(label: "com.story.continuous.session")
    private var videoDevice: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?

    // Increment 2 — front/rear switching. The CURRENT camera position; a swap rebuilds only the video
    // input inside begin/commitConfiguration (audio + outputs stay), gated out of .recording by the UI.
    private(set) var cameraPosition: AVCaptureDevice.Position = .back
    /// Whether a front camera exists (UI hides the flip button otherwise).
    var hasFrontCamera: Bool {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video, position: .front).devices.isEmpty == false
    }
    // Increment 2 — AE/AF lock. When locked, a scene change does NOT re-meter/refocus until unlocked.
    private(set) var isAELocked = false

    /// Device-supported zoom presets (e.g. 0.5×, 1×, 2×) derived from the ACTUAL virtual-device
    /// switch-over factors — NEVER a hardcoded lens list, so an SE with no ultra-wide/tele shows
    /// only [1×, 2×(digital)]. `1.0` is always present (the base wide). Published for the UI.
    private(set) var zoomPresets: [Double] = [1.0]
    /// Whether this device has a torch (UI hides the control when false).
    var hasTorch: Bool { videoDevice?.hasTorch ?? false }

    // Orientation (Increment 1 verify/fix): keep the movie-file + preview connections rotated to
    // match the physical device so portrait/landscape clips are recorded upright. iOS 17+ uses
    // RotationCoordinator (the Apple-recommended path); older iOS falls back to interface
    // orientation. Held as Any to avoid a hard availability type on the stored property.
    private var rotationCoordinator: Any?
    private var rotationObservations: [NSKeyValueObservation] = []

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

        // Prefer a VIRTUAL multi-camera device (triple/dual/dual-wide) when present: it exposes the
        // real optical lenses as zoom-factor switch-over points, so pinch + presets cross 0.5×/2×
        // optically where the hardware has them, and fall back to pure wide on an SE. This is NOT a
        // hardcoded lens list — unavailable lenses simply never appear.
        let device = Self.bestCamera(position: .back)
        if let camera = device,
           let videoInput = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(videoInput) {
            session.addInput(videoInput)
            self.videoDevice = camera
            self.videoDeviceInput = videoInput
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

        // Compute device-supported zoom presets from the ACTUAL hardware (no fake lenses).
        if let camera = device { self.zoomPresets = Self.zoomPresets(for: camera) }
        // Publish presets to the owner immediately so the zoom strip renders on OPEN (not lazily on
        // first tap). Dispatched to main because the delegate drives @Published UI state.
        let presets = self.zoomPresets
        DispatchQueue.main.async { [weak self] in self?.delegate?.captureEvent(.presetsReady(presets)) }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview

        // Orientation verify/fix: observe + apply rotation to preview + movie connections.
        configureRotationCoordinator()
    }

    // MARK: - Device selection & capability detection (per-device, never assumed)

    /// The best video device at a POSITION: a virtual multi-camera (triple → dual → dual-wide) when
    /// present so optical lenses are reachable via zoom, else the plain wide angle. Front typically has
    /// only wide (+ TrueDepth). Never fabricates lenses.
    private static func bestCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
            .builtInWideAngleCamera, .builtInTrueDepthCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferred, mediaType: .video, position: position)
        for type in preferred {
            if let d = discovery.devices.first(where: { $0.deviceType == type }) { return d }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Zoom presets expressed in the UI's "×" scale relative to the 1× wide lens. Derived from the
    /// device's real `virtualDeviceSwitchOverVideoZoomFactors` (ultra-wide gives 0.5×, each tele gives a
    /// switch-over e.g. 2×/3×/5×). The optical switch-overs are ANCHORS; `CameraZoomFormat.ladder`
    /// fills integer digital steps between them so the ramp is gradual (a [0.5,1,5] device becomes
    /// [0.5,1,2,3,5]) instead of a jarring 1→5 jump. Everything is clamped to the real max.
    private static func zoomPresets(for device: AVCaptureDevice) -> [Double] {
        // On a virtual device the base zoom (1.0 of videoZoomFactor) is the WIDEST active lens.
        // switchOver factors are videoZoomFactor thresholds where the lens changes.
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        // Real optical anchors in USER-× terms. With ultra-wide, raw factor 1.0 == 0.5× (1× == 2.0).
        var anchors: [Double] = []
        if hasUltraWide {
            anchors.append(0.5)
            anchors.append(1.0)
            for f in switchOvers where f > 2.0 { anchors.append((f / 2.0).rounded()) }
        } else {
            anchors.append(1.0)
            for f in switchOvers where f > 1.0 { anchors.append(f.rounded()) }
        }
        let maxUserZoom = device.maxAvailableVideoZoomFactor / (hasUltraWide ? 2.0 : 1.0)
        return CameraZoomFormat.ladder(anchors: anchors, maxUserZoom: maxUserZoom)
    }

    /// Convert a user-facing "×" value into the device's raw `videoZoomFactor`.
    /// On an ultra-wide virtual device, user 1× corresponds to raw factor 2.0 (0.5× == 1.0).
    private func rawZoomFactor(forUserZoom userZoom: Double) -> CGFloat {
        let hasUltraWide = videoDevice?.constituentDevices.contains {
            $0.deviceType == .builtInUltraWideCamera } ?? false
        return CGFloat(userZoom * (hasUltraWide ? 2.0 : 1.0))
    }

    /// Inverse of `rawZoomFactor`: the device's raw `videoZoomFactor` expressed in user-× terms, so the
    /// UI strip can show the live magnification (e.g. "2.7×") and highlight the nearest preset.
    private func userZoom(forRawFactor raw: CGFloat) -> Double {
        let hasUltraWide = videoDevice?.constituentDevices.contains {
            $0.deviceType == .builtInUltraWideCamera } ?? false
        return Double(raw) / (hasUltraWide ? 2.0 : 1.0)
    }

    /// Report the device's current zoom (user-×) to the owner on the main actor (drives the strip).
    private func reportZoom() {
        let user = userZoom(forRawFactor: videoDevice?.videoZoomFactor ?? 1.0)
        DispatchQueue.main.async { [weak self] in self?.delegate?.captureEvent(.zoomChanged(user)) }
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

    // MARK: - Camera controls (Package B Increment 1) — all ADDITIVE, serialized, lock-guarded.
    //
    // Every device mutation runs on `sessionQueue` inside lockForConfiguration/unlockForConfiguration,
    // so it is atomic and never races the recording state machine (which lives on main). None of these
    // touch the session topology (no begin/commitConfiguration, no input/output changes), so an
    // in-flight recording and a live AI scan are unaffected — zoom/focus/exposure/torch all adjust the
    // SAME running device both outputs already read from.

    private func configureDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        guard let device = videoDevice else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                body(device)
                device.unlockForConfiguration()
            } catch {
                // A transient lock failure must never crash or corrupt recording — ignore and keep going.
            }
        }
    }

    /// Set zoom by user-facing "×" value (from a preset button). Clamped to the device range.
    func setUserZoom(_ userZoom: Double) {
        configureDevice { [weak self] device in
            guard let self else { return }
            let raw = self.rawZoomFactor(forUserZoom: userZoom)
            let clamped = max(device.minAvailableVideoZoomFactor,
                              min(raw, device.maxAvailableVideoZoomFactor))
            device.videoZoomFactor = clamped
            self.reportZoom()
        }
    }

    /// Continuous pinch zoom. `scale` is the gesture's cumulative scale applied to the zoom factor
    /// at gesture start (`base`), so the ramp feels natural. Works during recording (device-level,
    /// no topology change). Clamped to the device's real min/max.
    func applyPinchZoom(scale: CGFloat, base: CGFloat) {
        configureDevice { [weak self] device in
            let target = base * scale
            let clamped = max(device.minAvailableVideoZoomFactor,
                              min(target, device.maxAvailableVideoZoomFactor))
            device.videoZoomFactor = clamped
            self?.reportZoom()
        }
    }

    /// The device's current raw zoom factor (gesture start reads this as its base).
    var currentZoomFactor: CGFloat { videoDevice?.videoZoomFactor ?? 1.0 }

    /// The device's zoom range expressed in USER-× terms (for the continuous thumb-dial). On an
    /// ultra-wide virtual device, raw 1.0 == user 0.5×, so user-min is raw-min / 2.
    var userZoomRange: ClosedRange<Double> {
        guard let d = videoDevice else { return 1...1 }
        let hasUltraWide = d.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let div = hasUltraWide ? 2.0 : 1.0
        let lo = Double(d.minAvailableVideoZoomFactor) / div
        let hi = Double(d.maxAvailableVideoZoomFactor) / div
        return lo...max(lo, hi)
    }

    /// Tap-to-focus + expose at a preview point (0..1 device coords from the preview layer). A tap also
    /// CLEARS any AE/AF lock and resumes continuous tracking — the native behavior (tap to re-meter).
    func focusAndExpose(atDevicePoint point: CGPoint) {
        configureDevice { [weak self] device in
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            }
            // Resume continuous tracking after a tap so the scene stays correctly focused/exposed as it
            // moves — this also lifts an AE/AF lock (tap overrides lock, like the native camera).
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if let self, self.isAELocked {
                self.isAELocked = false
                DispatchQueue.main.async { self.delegate?.captureEvent(.aeafLockChanged(false)) }
            }
        }
    }

    /// Convert a view-space tap into the device point-of-interest via the preview layer (handles
    /// resizeAspectFill cropping + mirroring correctly).
    func focusAndExpose(atViewPoint viewPoint: CGPoint) {
        guard let preview = previewLayer else { return }
        let devicePoint = preview.captureDevicePointConverted(fromLayerPoint: viewPoint)
        focusAndExpose(atDevicePoint: devicePoint)
    }

    /// Toggle the torch where present. No-op (and UI-hidden) on devices without one. Torch is a
    /// device property, independent of recording — safe to toggle mid-record.
    func setTorch(_ on: Bool) {
        configureDevice { device in
            guard device.hasTorch, device.isTorchModeSupported(on ? .on : .off) else { return }
            if on {
                try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
        }
    }

    // MARK: - Increment 2 controls — front/rear swap, exposure bias, AE/AF lock

    /// Flip between back and front cameras. Rebuilds ONLY the video input inside begin/commitConfiguration
    /// (audio input + movie/data outputs are untouched), then re-applies presets, orientation and zoom.
    /// REFUSED while recording — the UI gates the button out of .recording, and this is a second guard
    /// (a mid-clip input swap would corrupt the movie file). Runs on the session queue.
    func switchCamera() {
        guard phase != .recording, phase != .stopping else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let target: AVCaptureDevice.Position = (self.cameraPosition == .back) ? .front : .back
            guard let newDevice = Self.bestCamera(position: target),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }
            self.session.beginConfiguration()
            if let old = self.videoDeviceInput { self.session.removeInput(old) }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoDevice = newDevice
                self.videoDeviceInput = newInput
                self.cameraPosition = target
            } else if let old = self.videoDeviceInput {
                // Revert if the new input cannot be added (keep a working session).
                self.session.addInput(old)
            }
            self.session.commitConfiguration()

            // Re-derive presets for the new device, reset zoom to 1×, re-apply orientation.
            let presets = Self.zoomPresets(for: newDevice)
            self.zoomPresets = presets
            try? newDevice.lockForConfiguration()
            newDevice.videoZoomFactor = self.rawZoomFactor(forUserZoom: 1.0)
            newDevice.unlockForConfiguration()
            self.isAELocked = false
            let pos = self.cameraPosition
            DispatchQueue.main.async {
                self.delegate?.captureEvent(.presetsReady(presets))
                self.delegate?.captureEvent(.zoomChanged(1.0))
                self.delegate?.captureEvent(.aeafLockChanged(false))
                self.delegate?.captureEvent(.cameraPositionChanged(pos == .front))
                self.applyRotationForCurrentAPI()
            }
        }
    }

    /// Manual exposure bias in EV (e.g. −2…+2). Clamped to the device's real min/max target bias.
    /// Independent of recording. Does NOT engage the AE/AF lock — it biases the running auto-exposure.
    func setExposureBias(_ ev: Float) {
        configureDevice { device in
            let clamped = max(device.minExposureTargetBias, min(ev, device.maxExposureTargetBias))
            device.setExposureTargetBias(clamped, completionHandler: nil)
        }
    }

    /// The device's supported exposure-bias range (UI uses it to size the slider). Defaults to 0…0.
    var exposureBiasRange: ClosedRange<Float> {
        guard let d = videoDevice else { return 0...0 }
        return d.minExposureTargetBias...d.maxExposureTargetBias
    }

    /// Lock / unlock Auto-Exposure AND Auto-Focus at their current values (long-press AE/AF lock). While
    /// locked a scene change does NOT re-meter/refocus; a tap-to-focus clears the lock. Safe mid-record.
    func setAEAFLock(_ locked: Bool) {
        configureDevice { [weak self] device in
            if locked {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
            self?.isAELocked = locked
            DispatchQueue.main.async { self?.delegate?.captureEvent(.aeafLockChanged(locked)) }
        }
    }

    // MARK: - Orientation (Increment 1 verify/fix)
    //
    // The ORIGINAL engine never set any connection orientation, so a clip's upright-ness relied on
    // the sensor default — a confirmed defect for landscape capture. Fix: keep both the PREVIEW and
    // the MOVIE-FILE output connections rotated to match the physical device. iOS 17+ uses
    // AVCaptureDevice.RotationCoordinator (Apple-recommended, accounts for the device + the preview
    // layer); older iOS falls back to the interface orientation. The angle is NOT changed while a
    // recording is in flight — a mid-clip rotation would corrupt the file — so a recording keeps the
    // angle it started at and the next recording picks up the current one.

    /// Install rotation observation. Called once after `configureSession()`.
    private func configureRotationCoordinator() {
        if #available(iOS 17.0, *) {
            guard let device = videoDevice else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            self.rotationCoordinator = coordinator
            applyRotation()
            // Observe both angles; re-apply on change (but never mid-recording).
            rotationObservations = [
                coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.applyRotation() }
                },
                coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.applyRotation() }
                }
            ]
        } else {
            // Pre-17 fallback: apply once from the interface orientation and on device rotation.
            applyLegacyRotation()
            NotificationCenter.default.addObserver(
                self, selector: #selector(applyLegacyRotation),
                name: UIDevice.orientationDidChangeNotification, object: nil)
        }
    }

    /// iOS 17+ — push the coordinator's horizon-level angles onto the preview + movie connections.
    @available(iOS 17.0, *)
    private func applyRotation() {
        guard let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator else { return }
        if let pc = previewLayer?.connection, pc.isVideoRotationAngleSupported(coordinator.videoRotationAngleForHorizonLevelPreview) {
            pc.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        }
        // Do not re-rotate the movie connection while recording — the clip keeps its start angle.
        guard phase != .recording, phase != .stopping else { return }
        let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        if let mc = movieOutput.connection(with: .video), mc.isVideoRotationAngleSupported(captureAngle) {
            mc.videoRotationAngle = captureAngle
        }
    }

    /// Pre-iOS-17 — map the interface orientation to a rotation angle on both connections.
    @objc private func applyLegacyRotation() {
        let angle: CGFloat
        switch UIDevice.current.orientation {
        case .landscapeLeft: angle = 0      // home button right
        case .landscapeRight: angle = 180
        case .portraitUpsideDown: angle = 270
        default: angle = 90                 // portrait
        }
        if let pc = previewLayer?.connection, pc.isVideoRotationAngleSupported(angle) {
            pc.videoRotationAngle = angle
        }
        guard phase != .recording, phase != .stopping else { return }
        if let mc = movieOutput.connection(with: .video), mc.isVideoRotationAngleSupported(angle) {
            mc.videoRotationAngle = angle
        }
    }

    /// Version-agnostic rotation apply (used after a camera swap / on demand).
    private func applyRotationForCurrentAPI() {
        if #available(iOS 17.0, *) {
            // Rebuild the coordinator for the CURRENT device — a front/rear swap changes the device, and
            // the old coordinator would report the wrong device's angles (orientation-hardening).
            if let device = videoDevice {
                rotationObservations.removeAll()
                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
                self.rotationCoordinator = coordinator
                rotationObservations = [
                    coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                        DispatchQueue.main.async { self?.applyRotation() }
                    },
                    coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                        DispatchQueue.main.async { self?.applyRotation() }
                    }
                ]
            }
            applyRotation()
        } else {
            applyLegacyRotation()
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

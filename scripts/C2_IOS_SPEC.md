# C2 iOS Scene Scan — build spec (for worker)

DEVICE-ONLY Swift. Deliverable: NEW Swift files that pass `xcrun swiftc -parse <file>`
with ZERO `error:` lines (ignore lines containing "sandbox"). You CANNOT run Xcode.
Do NOT touch Python, or anything under packages/ apps/api/ evals/ contracts/ specs/.
Create NEW files only, except the one small edit at the end.

PROJECT: /Users/lingzhang/Workplace/story (iOS at apps/ios/Story/Story/)

READ FIRST to match style EXACTLY (dark theme bg Color(red:0.04,green:0.04,blue:0.043),
gold Color(red:0.83,green:0.66,blue:0.33); UIViewControllerRepresentable pattern; networking pattern):
- apps/ios/Story/Story/Media/Camera/CameraCaptureView.swift
- apps/ios/Story/Story/Media/Playback/MediaStore.swift
- apps/ios/Story/Story/Data/Contracts/CreativeIntentService.swift (StoryBackend.baseURL + StoryContractCoding + error enum)
- apps/ios/Story/Story/Data/Contracts/StoryContracts.swift (SceneUnderstandingContractDTO ALREADY EXISTS — decode it, do NOT redefine)
- apps/ios/Story/Story/Features/Capture/ShootMomentView.swift

CREATE:

1) apps/ios/Story/Story/Media/Camera/SceneScanController.swift
   UIViewControllerRepresentable `SceneScanView` + `SceneScanController: UIViewController`.
   Reuse AVCaptureSession (preset .high, back .builtInWideAngleCamera, NO audio). Live preview layer
   (set frame in viewDidLayoutSubviews; start/stop in viewWillAppear/Disappear like CameraCaptureView).
   Use AVCaptureVideoDataOutput + sample-buffer delegate to GRAB frames (NOT AVCaptureMovieFileOutput).
   "Scan" button starts ~4s capture; in the delegate throttle to ~1 frame/0.35s via timestamp; convert
   CMSampleBuffer->CVPixelBuffer->CIImage->CGImage->UIImage; collect candidates in memory. Auto-stop ~4s
   or Stop tap; Cancel button. On finish call `var onFrames: ([UIImage]) -> Void`; `var onCancel: () -> Void`.
   Write NOTHING to disk. Gold Scan button like CameraCaptureView's record button.

2) apps/ios/Story/Story/Media/SceneScan/SceneFrameProcessor.swift
   Pure struct, no I/O. `static func select(from candidates: [UIImage], max: Int = 5) -> [Data]`:
   a) blur rejection via a sharpness proxy `sharpness(_ image: UIImage) -> Double` using Core Image
      CIConvolution3X3 Laplacian kernel on a downscaled grayscale, variance of output. Drop low-sharpness
      (if all low, keep the sharper half).
   b) near-dup rejection via average-hash: downscale 8x8 grayscale -> 64-bit hash; drop if Hamming
      distance < 8 to an already-kept frame.
   c) cap to `max`, prefer sharper + diverse.
   d) resize longest side <= 1024px, JPEG quality 0.6 -> return [Data].
   Core Image/UIKit only, iOS 17+, helpers private.

3) apps/ios/Story/Story/Media/SceneScan/SceneScanStore.swift
   struct SceneScanStore, ephemeral cache dir FileManager.default.temporaryDirectory/"scene-scan".
   writeFrames([Data], sessionId: UUID) throws -> [URL] (under scene-scan/<sessionId>/), cleanup(sessionId),
   sweepStale() (remove whole scene-scan dir). TOP COMMENT: frames are EPHEMERAL inference inputs — NEVER
   Moments/Assets, NEVER MediaStore.adoptCapturedFile, never permanent. Minimal; guarantee cleanup.

4) apps/ios/Story/Story/Data/Contracts/SceneUnderstandingService.swift
   Mirror CreativeIntentService style. struct SceneUnderstandingService { var baseURL = StoryBackend.baseURL
   var session: URLSession = .shared; func analyze(frames: [Data], captureSessionId: UUID, mode: String,
   storyId: UUID?) async throws -> SceneUnderstandingContractDTO }. Hand-roll multipart/form-data POST to
   "v1/scene-understanding": one `context` part (application/json {"capture_session_id","mode","story_id"?})
   + one part per JPEG (name="frames", filename, Content-Type image/jpeg) with a boundary. Decode via
   StoryContractCoding.decoder(). Mirror error enum transport/unavailable(503)/badStatus/decoding + LocalizedError.

5) apps/ios/Story/Story/Features/SceneScan/SceneScanFlowView.swift
   SwiftUI. enum ScanState { intro, scanning, analyzing, success(SceneUnderstandingContractDTO), failed(String) }.
   intro: dark, title "Show me what's around you", subtitle "Slowly move your phone around the scene", gold
   "Start Scan". scanning: fullScreenCover SceneScanView; onFrames -> .analyzing + Task { SceneFrameProcessor.select
   -> SceneUnderstandingService.analyze -> .success / .failed }; always cleanup. analyzing: ProgressView + "Reading
   the scene…". success: read-only summary (summary text; environment_tags chips; subjects w/ prominence;
   operator_space; lighting; motion_opportunities & composition_opportunities bullet lists; constraints) in gold
   chip style; "Done" + "Rescan"(->intro). failed: message + "Try Again"(->intro) + "Cancel". NEVER fabricate on failure.
   Props: let captureSessionId: UUID = UUID(); let storyId: UUID?; let mode: String = "shoot_moment". No SwiftData writes,
   no Moment creation. UI must present observations, NOT shot ideas/directions.

EDIT (minimal, show a unified diff):
A) apps/ios/Story/Story/Features/Capture/ShootMomentView.swift — add a secondary (outline-style) button
   "Show me what's around you" ABOVE "Open Camera" that presents SceneScanFlowView(storyId: story.id) in a
   fullScreenCover. Do not change the existing direction/camera flow.

CONTRACT (authoritative, snake_case wire; already decoded by SceneUnderstandingContractDTO): id, summary,
environment_tags[], subjects[{label,note?,prominence?}], lighting?, operator_space?, motion_opportunities[],
composition_opportunities[], constraints[], created_at. Do NOT invent fields.

VERIFY: run `xcrun swiftc -parse` on each new + the edited file; filter out "sandbox" lines; confirm ZERO
"error:" lines. Report files created/edited, parse result per file, and a unified diff for the edited file.
Do NOT build the whole app or run the backend.

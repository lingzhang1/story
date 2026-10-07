import SwiftUI
import SwiftData

// SceneScanFlowView — the DIRECT consumer flow (Milestone C3B).
//
//   intro
//     -> scanning (live capture)
//     -> analyzing      ("Looking at your scene…")      [SceneUnderstanding]
//     -> planning       ("Finding the best way to capture this…") [Director]
//     -> recommendation (ONE Director recommendation + shot guidance)
//     -> camera (real capture) -> Moment -> dismiss
//
// The user experiences Story's CONCLUSION, not its pipeline. Raw
// SceneUnderstanding / StoryPlan / beats are hidden behind a DEBUG disclosure
// (§3, §4). On failure we surface a recoverable retry and NEVER fabricate a
// scene read or a recommendation (§8). No real Shot Validation (that is C4);
// after capture we use the existing accepted-capture behavior.
struct SceneScanFlowView: View {
    enum FlowState {
        case intro
        case scanning
        case analyzing                                   // SceneUnderstanding in flight
        case planning(SceneUnderstandingContractDTO?)    // Director in flight (nil = Skip Scan)
        case recommendation(SceneUnderstandingContractDTO?, DirectorOutputDTO)
        case failed(String, retry: RetryKind)
    }
    enum RetryKind { case rescan, replan(SceneUnderstandingContractDTO?) }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var story: StoryModel

    /// E2-c: the high-level narrative opportunity the user chose (Story Idea -> Show me, or Guide
    /// possibility -> Shoot). nil = the existing direct "Shoot a moment" flow (unchanged). Stored on
    /// the view, so it SURVIVES rescan (rescan only resets `state`, not this value).
    var selectedOpportunity: SelectedOpportunityDTO? = nil

    let captureSessionId: UUID = UUID()
    let mode: String = "shoot_moment"

    @State private var state: FlowState = .intro
    @State private var showCamera = false
    @State private var lastScanToRecommendationMs: Int?
    @State private var planningLine = "Looking at your scene…"
    @State private var planningTimer: Timer?
    @State private var sceneFrame: UIImage?   // sharpest scanned frame, backs the Idea card

    // C4-Lite capture integrity (Milestone C4-Lite). SAVE does not interrupt (brief
    // "Moment added" confirmation only); only FAIL interrupts with a physical reason.
    @State private var showMomentAdded = false                       // neutral SAVE toast
    @State private var integrityFail: CaptureIntegrityIssue?         // non-nil => FAIL sheet
    @State private var pendingCaptureURL: URL?                       // held for Keep-anyway
    @State private var pendingCaptureDuration: Double = 0
    // Milestone D: capture context (requested Shot/Beat) for the AU job, set when the
    // camera opens from a Director recommendation; nil for Skip Scan (contextless Moment).
    @State private var pendingCaptureContext: [String: Any]?
    private let integrityChecker = CaptureIntegrityChecker()

    // DIRECT UX: which alternative candidate is currently displayed (0 = primary).
    // "Try another idea" advances this locally — NO new Director call.
    @State private var candidateIndex = 0

    private let sceneService = SceneUnderstandingService()
    private let directorService = StoryDirectorService()

    // Staged consumer copy for the real ~12–16s Director wait (no fake %).
    private let planningStages = [
        "Looking at your scene…",
        "Finding what matters…",
        "Finding a shot worth capturing…"
    ]

    private let bg = Color(red: 0.04, green: 0.04, blue: 0.043)
    private let gold = Color(red: 0.83, green: 0.66, blue: 0.33)
    private let ink = Color(red: 0.96, green: 0.94, blue: 0.91)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            switch state {
            case .intro:                      introView
            case .scanning:                   Color.clear
            case .analyzing:                  statusView("Looking at your scene…")
            case .planning:                   statusView(planningLine)
            case .recommendation(let su, let out): recommendationView(su, out)
            case .failed(let message, let retry): failedView(message, retry)
            }
        }
        .fullScreenCover(isPresented: scanningBinding) {
            SceneScanView(
                onFrames: { frames in handleFrames(frames) },
                onCancel: { state = .intro }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(
                onFinish: { url, dur in handleCapture(tempURL: url, duration: dur) },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        // C4-Lite FAIL surface — ONLY an obvious integrity failure interrupts. Physical
        // reason + Try again / Keep anyway. Retake is optional (Keep anyway persists).
        .sheet(isPresented: integrityFailBinding) {
            captureIntegrityFailSheet()
        }
        // C4-Lite SAVE — neutral, non-interrupting "Moment added" confirmation. No
        // Continue button, no spinner, no validation page. Auto-dismisses the flow.
        .overlay(alignment: .bottom) {
            if showMomentAdded {
                Text("Moment added")
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var integrityFailBinding: Binding<Bool> {
        Binding(get: { integrityFail != nil },
                set: { if !$0 { integrityFail = nil } })
    }

    // C4-Lite FAIL sheet: a physical, non-semantic explanation + two optional choices.
    @ViewBuilder
    private func captureIntegrityFailSheet() -> some View {
        let issue = integrityFail ?? .tooShort
        VStack(spacing: 22) {
            Spacer()
            Text(issue.userReason)                       // physical only, never semantic
                .font(.system(size: 22, weight: .light, design: .serif))
                .foregroundStyle(ink).multilineTextAlignment(.center)
            Spacer()
            primaryButton("Try again") {                 // discard pending, re-open camera
                integrityFail = nil
                pendingCaptureURL = nil
                showCamera = true
            }
            secondaryButton("Keep anyway") {             // user override -> persist as Moment
                integrityFail = nil
                keepPendingAnyway()
            }
        }
        .padding(28)
        .presentationDetents([.medium])
        .background(bg.ignoresSafeArea())
    }

    private var scanningBinding: Binding<Bool> {
        Binding(
            get: { if case .scanning = state { return true } else { return false } },
            set: { presenting in if !presenting, case .scanning = state { state = .intro } }
        )
    }

    // MARK: - intro

    private var introView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text("Show me what's around you")
                .font(.system(size: 32, weight: .light, design: .serif))
                .foregroundStyle(ink)
            Text("Slowly move your phone around the scene")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(ink.opacity(0.7))
            Spacer()
            primaryButton("Start Scan") { state = .scanning }
            secondaryButton("Skip Scan") { pendingCaptureContext = nil; showCamera = true }   // shoot immediately — no scan, no Director, no wait, no context
            Button("Cancel") { dismiss() }
                .foregroundStyle(.gray).frame(maxWidth: .infinity)
        }
        .padding(24)
    }

    // MARK: - status (analyzing / planning) — consumer language, never jargon

    private func statusView(_ label: String) -> some View {
        VStack(spacing: 20) {
            ProgressView().tint(gold).scaleEffect(1.4)
            Text(label)
                .font(.system(size: 20, weight: .light, design: .serif))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    // MARK: - recommendation (the Director's ONE strong next action)

    private func recommendationView(_ su: SceneUnderstandingContractDTO?,
                                    _ out: DirectorOutputDTO) -> some View {
        // DIRECT UX: show ONE candidate at a time. candidates[0] == decision; fall back to
        // the single decision when the server returned no candidates. "Try another idea"
        // advances candidateIndex locally (no new Director call).
        let candidates: [DirectorDecisionDTO] = out.candidates.isEmpty ? [out.decision] : out.candidates
        let idx = min(candidateIndex, candidates.count - 1)
        let current = candidates[idx]
        let hasMore = idx < candidates.count - 1
        let action = current.action
        let shot = current.shot ?? (action == .captureShot || action == .retryShot
                                         ? out.plan.shots.first : nil)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch action {
                case .captureShot, .retryShot:
                    // Concept Card (11-direct-flow) over the real scanned scene
                    // (Figma idea.png: image-backed card + "SHOT 1" label), then
                    // the shot instruction + guidance. Visual-first, no jargon.
                    VStack(alignment: .leading, spacing: 0) {
                        if let sceneFrame {
                            Color.clear
                                .frame(height: 200).frame(maxWidth: .infinity)
                                .overlay(Image(uiImage: sceneFrame).resizable().scaledToFill())
                                .overlay(
                                    LinearGradient(
                                        stops: [.init(color: bg.opacity(0.96), location: 0),
                                                .init(color: bg.opacity(0.25), location: 0.6),
                                                .init(color: .clear, location: 1)],
                                        startPoint: .bottom, endPoint: .top)
                                )
                                .clipped()
                                .overlay(alignment: .topLeading) {
                                    Text("SHOT 1").font(StoryTheme.body(11, .semibold))
                                        .tracking(1.5).foregroundStyle(gold)
                                        .padding(14)
                                }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(out.concept.title)
                                .font(StoryTheme.display(26))
                                .foregroundStyle(ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if !out.concept.summary.isEmpty {
                                Text(out.concept.summary)
                                    .font(StoryTheme.body(16, .light))
                                    .foregroundStyle(ink.opacity(0.82))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text(conceptMeta(out))
                                .font(StoryTheme.body(13)).foregroundStyle(gold)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(sceneFrame == nil ? 0 : 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sceneFrame == nil ? Color.clear : bg.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: sceneFrame == nil ? 0 : 18))
                    if let shot {
                        Divider().overlay(gold.opacity(0.25)).padding(.vertical, 4)
                        Text(shot.instruction)
                            .font(StoryTheme.display(20))
                            .foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 10) {
                            if let a = shot.subjectAction, !a.isEmpty { guidanceRow("Subject", a) }
                            if let m = shot.cameraMotion, !m.isEmpty { guidanceRow("You", friendlyMotion(m)) }
                            if let d = shot.targetDurationSeconds { guidanceRow("Hold", "about \(Int(d.rounded())) seconds") }
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 12)
                    primaryButton("Let's shoot") {
                        // Carry the requested Shot/Beat as AU capture context (06 §1).
                        var ctx: [String: Any] = [:]
                        if let shot {
                            var s: [String: Any] = [:]
                            s["instruction"] = shot.instruction
                            if let a = shot.subjectAction { s["subject_action"] = a }
                            if let m = shot.cameraMotion { s["camera_motion"] = m }
                            ctx["shot"] = s
                        }
                        if let beatId = out.plan.shots.first?.beatId {
                            ctx["beat"] = ["id": beatId]
                        }
                        pendingCaptureContext = ctx.isEmpty ? nil : ctx
                        showCamera = true
                    }
                    // DIRECT UX: only one recommendation visible at a time. Advance to the
                    // next alternative INSTANTLY (local, no new Director call). Hidden on the
                    // last available candidate (no endless regeneration loop).
                    if hasMore {
                        secondaryButton("Try another idea") {
                            withAnimation { candidateIndex = idx + 1 }
                        }
                    }
                    secondaryButton("Rescan") { state = .intro }

                case .rescanScene:
                    // Director declined this scene — do NOT offer the camera / an empty shot.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Let's find a better moment").font(.headline).foregroundStyle(gold)
                        Text("This scene doesn't quite fit your Story")
                            .font(.system(size: 26, weight: .light, design: .serif))
                            .foregroundStyle(ink)
                    }
                    Text("Point your phone at something that connects to what you're making, and scan again.")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    primaryButton("Scan again") { state = .intro }

                case .createNow:
                    // Enough material — nothing to shoot here.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("You've got what you need").font(.headline).foregroundStyle(gold)
                        Text(out.concept.title)
                            .font(.system(size: 26, weight: .light, design: .serif))
                            .foregroundStyle(ink)
                    }
                    Text("Story has enough to work with. You can create your Story now.")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    primaryButton("Done") { dismiss() }
                    secondaryButton("Scan again") { state = .intro }
                }

                Button("Cancel") { dismiss() }
                    .foregroundStyle(.gray).frame(maxWidth: .infinity)

                #if DEBUG
                if AppMode.current.showsDiagnostics, let su {   // no scene panel on Skip Scan
                    DirectorDebugPanel(story: story,
                                       creativeIntent: CreativeIntentContractDTO(from: story),
                                       scene: su,
                                       output: out,
                                       scanToRecommendationMs: lastScanToRecommendationMs)
                        .padding(.top, 16)
                }
                #endif
            }
            .padding(24)
            .padding(.top, 8)
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).foregroundStyle(gold).frame(maxWidth: .infinity)
    }

    /// "N shots · ~X sec" summary for the Concept Card (11-direct-flow). Uses the
    /// plan's estimated duration, falling back to summed shot target durations.
    private func conceptMeta(_ out: DirectorOutputDTO) -> String {
        let shots = out.plan.shots.count
        let shotLabel = shots == 1 ? "1 shot" : "\(shots) shots"
        let secs = out.plan.estimatedDurationSeconds
            ?? out.plan.shots.compactMap { $0.targetDurationSeconds }.reduce(0, +)
        if secs > 0 { return "\(shotLabel) · ~\(Int(secs.rounded())) sec" }
        return shotLabel
    }

    private func guidanceRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).font(.caption).foregroundStyle(gold)
                .frame(width: 60, alignment: .leading)
            Text(v).font(.subheadline).foregroundStyle(ink.opacity(0.85))
        }
    }

    /// Translate contract camera_motion into plain operator language.
    private func friendlyMotion(_ motion: String) -> String {
        switch motion.lowercased() {
        case "static", "none", "hold": return "hold still"
        case "pan": return "slowly turn the phone"
        case "tilt": return "slowly tip the phone up or down"
        case "follow", "track": return "follow them smoothly"
        case "push_in", "dolly_in": return "step slowly toward them"
        default: return motion.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: - failed (recoverable)

    private func failedView(_ message: String, _ retry: RetryKind) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text(message)
                .font(.system(size: 20, weight: .light, design: .serif))
                .foregroundStyle(ink).multilineTextAlignment(.center)
            Spacer()
            primaryButton("Try Again") {
                switch retry {
                case .rescan: state = .intro
                case .replan(let su): runDirector(su)
                }
            }
            Button("Cancel") { dismiss() }
                .foregroundStyle(.gray).frame(maxWidth: .infinity)
        }
        .padding(24)
    }

    // MARK: - pipeline

    private func handleFrames(_ frames: [UIImage]) {
        sceneFrame = frames.first   // real scanned scene → backs the Idea card (Figma)
        state = .analyzing
        let scanStart = Date()
        Task {
            do {
                let selected = SceneFrameProcessor.select(from: frames, max: 5)
                let su = try await sceneService.analyze(
                    frames: selected, captureSessionId: captureSessionId,
                    mode: mode, storyId: story.id)
                await MainActor.run { runDirector(su, scanStart: scanStart) }
            } catch {
                await MainActor.run {
                    state = .failed(errorText(error, "Something went wrong reading the scene."),
                                    retry: .rescan)
                }
            }
        }
    }

    private func runDirector(_ su: SceneUnderstandingContractDTO?, scanStart: Date? = nil) {
        state = .planning(su)
        startPlanningStages()
        let start = scanStart ?? Date()
        Task {
            do {
                let out = try await directorService.initialize(
                    creativeIntent: CreativeIntentContractDTO(from: story),
                    sceneUnderstanding: su,
                    targetDurationSeconds: story.intentTargetDurationSeconds,
                    selectedOpportunity: selectedOpportunity)   // nil for the direct flow; survives rescan
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                await MainActor.run {
                    stopPlanningStages()
                    lastScanToRecommendationMs = ms
                    candidateIndex = 0                      // show primary first
                    state = .recommendation(su, out)
                }
            } catch {
                await MainActor.run {
                    stopPlanningStages()
                    state = .failed(errorText(error, "Story couldn't plan this shot."),
                                    retry: .replan(su))
                }
            }
        }
    }

    private func startPlanningStages() {
        planningLine = planningStages[0]
        var i = 0
        planningTimer?.invalidate()
        planningTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            i = min(i + 1, planningStages.count - 1)
            withAnimation { planningLine = planningStages[i] }
        }
    }
    private func stopPlanningStages() { planningTimer?.invalidate(); planningTimer = nil }

    private func handleCapture(tempURL: URL, duration: Double) {
        // C4-Lite capture-integrity gate (local, synchronous, no AI/network/AWS).
        // SAVE -> persist Moment + neutral "Moment added" + continue (no interruption).
        // FAIL -> do NOT auto-adopt; interrupt with a physical reason + Try again / Keep
        // anyway. NO semantic claim is made; BeatProgress is NOT updated here.
        showCamera = false
        let verdict = integrityChecker.evaluate(fileURL: tempURL)
        switch verdict {
        case .save:
            persistMoment(tempURL: tempURL, duration: duration)
        case .fail(let issue):
            // Hold the capture so "Keep anyway" can still adopt it.
            pendingCaptureURL = tempURL
            pendingCaptureDuration = duration
            integrityFail = issue
        }
    }

    /// Persist a captured clip as a Moment via the existing path, then show the neutral
    /// SAVE confirmation and leave the flow. No semantic shot/beat claim is attached.
    private func persistMoment(tempURL: URL, duration: Double) {
        let useCases = StoryUseCases(repository: StoryRepository(context: context))
        do {
            let relativePath = try MediaStore.shared.adoptCapturedFile(tempURL: tempURL)
            let moment = try useCases.shootMoment(for: story, relativePath: relativePath,
                                                  durationSeconds: duration)
            pendingCaptureURL = nil
            // Milestone D §6: enqueue an Asset Understanding job AFTER the Moment is
            // persisted. Moment creation NEVER blocks on AU; the job runs opportunistically
            // (here + on launch/network). Capture context is the requested Shot/Beat when the
            // camera came from a recommendation, nil for Skip Scan (contextless Moment).
            let auQueue = AssetUnderstandingQueue(context: context)
            auQueue.enqueue(
                momentId: moment.id,
                relativeMediaPath: relativePath,
                sourceCaptureId: captureSessionId,
                captureContext: pendingCaptureContext
            )
            pendingCaptureContext = nil
            Task { await auQueue.drain() }   // opportunistic; failures leave the job PENDING
            // Milestone D §13: also save a user-owned COPY to Apple Photos (add-only),
            // fire-and-forget. The Moment is ALREADY persisted above; this never blocks
            // or fails Moment creation, and Photos denial/failure degrades silently.
            let adoptedURL = MediaStore.shared.absoluteURL(for: relativePath)
            PhotosSaver.saveVideoCopy(at: adoptedURL) { outcome in
                if outcome != .saved { print("Photos copy not saved: \(outcome)") }
            }
            withAnimation { showMomentAdded = true }
            // Brief confirmation, then continue the normal Story flow.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation { showMomentAdded = false }
                dismiss()
            }
        } catch {
            print("Failed to save moment: \(error)")
            dismiss()
        }
    }

    /// "Keep anyway" override on a FAIL: persist the held capture as a Moment despite the
    /// integrity flag. Still no semantic claim.
    private func keepPendingAnyway() {
        guard let url = pendingCaptureURL else { dismiss(); return }
        persistMoment(tempURL: url, duration: pendingCaptureDuration)
    }

    private func errorText(_ error: Error, _ fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }

    // MARK: - shared

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline)
                .frame(maxWidth: .infinity).padding()
                .background(gold).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

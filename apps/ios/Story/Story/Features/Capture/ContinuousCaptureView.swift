import SwiftUI
import SwiftData
import UIKit

// ContinuousCaptureView — the native-camera-like capture screen (Figma MVP V0.2.2).
//
// ONE screen for both entry points; CaptureContext (75435fa) decides only the
// Story association. Behavior (Increment 2):
//   • Red record button = primary action; tap to record, tap to stop.
//   • Each finished clip is finalized + persisted as exactly ONE Moment, then the
//     camera STAYS OPEN, ready for the next recording. No "Moment saved" page,
//     no "Capture another".
//   • Subtle, non-blocking save feedback ("Saved" pill); the recent-Moment
//     thumbnail (bottom-left) updates ONLY after successful persistence.
//   • Saves are serialized (an actor-free @MainActor queue) so a fast second
//     recording cannot race the first save; AU + Photos copy run async and
//     NEVER block the next recording.
//
// AI Ideas (the "Get an AI shot idea" pill + scan overlay) is wired in Increment 4;
// here the pill is present but routes to a no-op hook so the camera is fully usable
// without AI (spec: AI is user-initiated and never required to record).
struct ContinuousCaptureView: View {
    let captureContext: CaptureContext
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = ContinuousCaptureModel()

    @State private var showLibrary = false

    private let gold = Color(red: 0.83, green: 0.66, blue: 0.33)
    private let ink = Color(red: 0.96, green: 0.94, blue: 0.91)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Live camera preview (full-bleed), hosting the shared engine.
            ContinuousCameraHost(model: model).ignoresSafeArea()

            // Chrome overlay (Figma V0.2.2).
            VStack {
                topBar
                Spacer()
                bottomControls
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)

            // Subtle, non-blocking save feedback.
            if model.showSaved {
                Text("Saved")
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
        .onAppear { model.configure(context: context, captureContext: captureContext) }
        // Phase 1: the recent-Moment thumbnail opens the GLOBAL library in a browse-only
        // (.recentBrowse) cover PRESENTED OVER the camera — the camera session beneath is
        // preserved (not torn down), so closing returns straight to a ready camera. No new
        // camera session is created. Navigation is gated OFF while recording (see thumbnail
        // button) so an in-flight clip is never interrupted.
        .fullScreenCover(isPresented: $showLibrary) {
            NavigationStack { MomentsLibraryView(libraryContext: .recentBrowse) }
        }
        .alert("Couldn't save that clip", isPresented: $model.showError, actions: {
            Button("OK", role: .cancel) {}
        }, message: { Text(model.errorMessage ?? "Please try again.") })
    }

    // MARK: - Top bar: ✕ close · "Saves to Moments" pill (or REC + timer while recording)
    private var topBar: some View {
        ZStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
                .disabled(model.isRecording)   // don't allow leaving mid-recording via the ✕
                .opacity(model.isRecording ? 0.35 : 1)
                Spacer()
            }
            if model.isRecording {
                recordingIndicator
            } else {
                Text(destinationLabel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.black.opacity(0.35), in: Capsule())
            }
        }
    }

    // Phase 2: prominent REC indicator + elapsed timer (pulsing red dot).
    private var recordingIndicator: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 0.92, green: 0.22, blue: 0.22))
                .frame(width: 10, height: 10)
                .modifier(RecordingPulse())
            Text("REC").font(.system(size: 13, weight: .bold)).tracking(1).foregroundStyle(.white)
            Text(model.recordingTimeString)
                .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.black.opacity(0.5), in: Capsule())
        .accessibilityLabel("Recording, \(model.recordingTimeString)")
    }

    private var destinationLabel: String {
        if let s = captureContext.associatedStory { return "Adds to \(s.title)" }
        return "Saves to Moments"
    }

    // MARK: - Bottom: AI overlays · recent thumbnail · record button
    private var bottomControls: some View {
        VStack(spacing: 20) {
            // AI Ideas region (Figma V0.2.2). The record button below stays live in
            // EVERY state — scanning and inference never block recording. While RECORDING,
            // the AI overlay is hidden entirely (Phase 2: "AI overlay minimized or hidden").
            if model.isRecording {
                EmptyView()
            } else {
                switch model.aiState {
                case .off:
                    aiIdeaPill
                case .scanning:
                    scanningPanel
                case .thinking:
                    thinkingPanel
                case .ideas:
                    ideaCard
                case .failed(let msg):
                    failedNote(msg)
                }
            }

            HStack {
                // Recent Moment thumbnail (bottom-left) — updates after persistence.
                // Phase 1: opens the global Moments Library (browse-only) OVER the camera;
                // closing returns here. DISABLED while recording so an in-flight clip is
                // never interrupted (deferred until the user stops).
                Button {
                    guard !model.isRecording else { return }
                    showLibrary = true
                } label: {
                    recentThumbnail
                }
                .frame(width: 56, height: 56)
                .disabled(model.isRecording)
                .opacity(model.isRecording ? 0.4 : 1)
                .accessibilityLabel("Recent moments")

                Spacer()

                // Red record / stop button with white + teal ring (Figma).
                Button {
                    model.toggleRecording()
                } label: {
                    ZStack {
                        Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                        Circle().strokeBorder(gold.opacity(0.5), lineWidth: 2).frame(width: 86, height: 86)
                        if model.isRecording {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 0.86, green: 0.26, blue: 0.26))
                                .frame(width: 32, height: 32)
                        } else {
                            Circle()
                                .fill(Color(red: 0.86, green: 0.26, blue: 0.26))
                                .frame(width: 62, height: 62)
                        }
                    }
                }
                // Never disabled: the next recording is allowed even while the
                // previous Moment is still being saved/analyzed (saves are serialized).

                Spacer()

                // Right spacer to visually center the record button opposite the thumbnail.
                Color.clear.frame(width: 56, height: 56)
            }
        }
    }

    // "Get an AI shot idea" entry pill.
    private var aiIdeaPill: some View {
        Button {
            model.getAIShotIdeaTapped()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 14))
                Text("Get an AI shot idea").font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(panelBG, in: Capsule())
        }
    }

    // Scanning state (Figma: "SCANNING SCENE" + keep-recording hint + Cancel). This is the
    // frame-collection phase — distinct from the "thinking" (Director) phase below.
    private var scanningPanel: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("SCANNING SCENE", systemImage: "viewfinder")
                        .font(.system(size: 13, weight: .semibold)).tracking(1)
                        .foregroundStyle(gold)
                    Spacer()
                    ProgressView().tint(gold).scaleEffect(0.8)
                }
                Text("Slowly look around. You can keep recording.")
                    .font(.system(size: 15)).foregroundStyle(ink.opacity(0.9))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelBG, in: RoundedRectangle(cornerRadius: 16))

            Button { model.dismissIdeas() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    Text("Cancel scan").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(ink)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(panelBG, in: Capsule())
            }
        }
    }

    // Thinking state (Phase 2): frames are collected; the Director is generating an idea.
    // Honest spinner — NO fabricated progress percentage.
    private var thinkingPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().tint(gold).scaleEffect(0.9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FINDING A SHOT IDEA")
                        .font(.system(size: 13, weight: .semibold)).tracking(1).foregroundStyle(gold)
                    Text("Reading the scene you just captured.")
                        .font(.system(size: 14)).foregroundStyle(ink.opacity(0.85))
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelBG, in: RoundedRectangle(cornerRadius: 16))

            Button { model.dismissIdeas() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    Text("Cancel").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(ink)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(panelBG, in: Capsule())
            }
        }
    }

    // Generated shot idea card (Figma: "SHOT IDEA · N SEC / ✕", title, body,
    // pagination + "Next idea · i of n", "Scan again for another idea").
    private var ideaCard: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(ideaEyebrow)
                        .font(.system(size: 13, weight: .semibold)).tracking(1).foregroundStyle(gold)
                    Spacer()
                    Button { model.dismissIdeas() } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.7))
                    }
                }
                Text(model.currentIdeaTitle)
                    .font(.system(size: 22, weight: .regular, design: .serif)).foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.currentIdeaBody.isEmpty {
                    Text(model.currentIdeaBody)
                        .font(.system(size: 15)).foregroundStyle(ink.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.ideaCount > 1 {
                    Divider().overlay(gold.opacity(0.2)).padding(.vertical, 2)
                    HStack {
                        HStack(spacing: 6) {
                            ForEach(0..<model.ideaCount, id: \.self) { i in
                                Capsule()
                                    .fill(i == model.ideaIndex ? gold : ink.opacity(0.25))
                                    .frame(width: i == model.ideaIndex ? 16 : 6, height: 6)
                            }
                        }
                        Spacer()
                        Button { model.nextIdea() } label: {
                            Text("Next idea · \(model.ideaIndex + 1) of \(model.ideaCount) ›")
                                .font(.system(size: 14, weight: .medium)).foregroundStyle(ink.opacity(0.9))
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelBG, in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 10) {
                Button { model.scanAgain() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: 14))
                        Text("Scan again").font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(panelBG, in: Capsule())
                }
                Button { model.letsShoot() } label: {
                    Text("Let's shoot").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(gold, in: Capsule())
                }
            }
        }
    }

    private var ideaEyebrow: String {
        if let s = model.currentIdeaSeconds { return "SHOT IDEA · \(s) SEC" }
        return "SHOT IDEA"
    }

    // AI failed/throttled — honest, dismissible. Recording still works.
    private func failedNote(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Text(msg).font(.system(size: 14)).foregroundStyle(ink.opacity(0.9))
            Spacer()
            Button("Try again") { model.scanAgain() }
                .font(.system(size: 14, weight: .medium)).foregroundStyle(gold)
            Button { model.dismissIdeas() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.6))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(panelBG, in: RoundedRectangle(cornerRadius: 14))
    }

    private var panelBG: Color { Color(red: 0.09, green: 0.12, blue: 0.12).opacity(0.9) }

    @ViewBuilder
    private var recentThumbnail: some View {
        if let img = model.recentThumbnail {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.6), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.12))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 18)).foregroundStyle(.white.opacity(0.5)))
        }
    }
}

// UIViewControllerRepresentable host that binds the shared engine to the model.
private struct ContinuousCameraHost: UIViewControllerRepresentable {
    @ObservedObject var model: ContinuousCaptureModel

    func makeUIViewController(context: Context) -> ContinuousCameraController {
        let c = ContinuousCameraController()
        c.delegate = model
        model.controller = c
        return c
    }
    func updateUIViewController(_ controller: ContinuousCameraController, context: Context) {}
}

// A gentle opacity pulse for the REC dot. Respects Reduce Motion (holds steady when enabled).
private struct RecordingPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion ? 1 : (on ? 0.35 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

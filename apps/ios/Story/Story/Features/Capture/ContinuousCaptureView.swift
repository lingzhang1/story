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
        .alert("Couldn't save that clip", isPresented: $model.showError, actions: {
            Button("OK", role: .cancel) {}
        }, message: { Text(model.errorMessage ?? "Please try again.") })
    }

    // MARK: - Top bar: ✕ close · "Saves to Moments" pill
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
                Spacer()
            }
            Text(destinationLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.black.opacity(0.35), in: Capsule())
        }
    }

    private var destinationLabel: String {
        if let s = captureContext.associatedStory { return "Adds to \(s.title)" }
        return "Saves to Moments"
    }

    // MARK: - Bottom: AI pill · recent thumbnail · record button
    private var bottomControls: some View {
        VStack(spacing: 20) {
            // "Get an AI shot idea" pill — present but AI wiring lands in Increment 4.
            // Never blocks recording; hidden while recording (Figma shows it absent then).
            if !model.isRecording {
                Button {
                    model.getAIShotIdeaTapped()   // Increment 4 hook (no-op now)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: 14))
                        Text("Get an AI shot idea").font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Color(red: 0.09, green: 0.12, blue: 0.12).opacity(0.85), in: Capsule())
                }
            }

            HStack {
                // Recent Moment thumbnail (bottom-left) — updates after persistence.
                Button {
                    dismiss()   // return to the library/story that owns these Moments
                } label: {
                    recentThumbnail
                }
                .frame(width: 56, height: 56)

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

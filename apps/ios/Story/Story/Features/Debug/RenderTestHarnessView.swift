#if DEBUG
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// RenderTestHarnessView — DEBUG-ONLY internal developer surface (Milestone R-b §3). NOT the consumer Create My
// Story flow and NOT compiled into Release. Lets the owner render a known-valid EditPlan/2 fixture (or a real
// plan from the deployed Edit Planner) over an existing Story's local Moments, play the MP4, inspect it, and
// save/share. No Epidemic; optional LOCAL test soundtrack only.
struct RenderTestHarnessView: View {
    @Bindable var story: StoryModel

    @State private var media: [MomentMedia] = []
    @State private var status: String = "Idle"
    @State private var progress: Float = 0
    @State private var player: AVPlayer?
    @State private var result: RenderResult?
    @State private var rendering = false
    @State private var useRealPlan = false
    @State private var cancelFlag = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Story") {
                    Text(story.title).font(.headline)
                    Text("\(media.count) resolvable Moments").foregroundStyle(.secondary)
                }
                Section("Plan source") {
                    Toggle("Use real Edit Planner (/v1/edit-plan)", isOn: $useRealPlan)
                        .disabled(true)   // enabled once the backend is confirmed deployed (R-b §4)
                    Text(useRealPlan ? "Real AI plan (requires deployed backend)"
                                     : "Deterministic montage fixture (no network)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Render") {
                    Button(rendering ? "Rendering…" : "Render Test Story") { Task { await renderFixture() } }
                        .disabled(rendering || media.isEmpty)
                    if rendering {
                        ProgressView(value: progress)
                        Button("Cancel", role: .destructive) { cancelFlag = true }
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if let result {
                    Section("Result") {
                        Text(String(format: "duration %.2fs · %.0f×%.0f",
                                    result.durationSeconds, result.renderSize.width, result.renderSize.height))
                        if let player {
                            VideoPlayer(player: player).frame(height: 360)
                        }
                        Button("Save to Photos") { PhotosSaver.saveVideoCopy(at: result.url) }
                        ShareLink(item: result.url) { Text("Share / Save to Files") }
                    }
                }
            }
            .navigationTitle("Render Test (DEBUG)")
            .onAppear { media = MomentResolver.resolve(moments: story.moments) }
        }
    }

    private func renderFixture() async {
        rendering = true; cancelFlag = false; progress = 0; status = "Building plan…"; result = nil; player = nil
        let plan = DebugEditPlanFixture.montage(media: media)
        let inputs = MediaEngineInputs(
            plan: plan,
            resolveMomentURL: MomentResolver.urlResolver(for: media),
            soundtrackURL: nil,                      // no soundtrack for the first render (no Epidemic)
            musicAnalysis: nil,
            soundtrackRole: "supportive", nativeAudioPriority: "selective")
        do {
            status = "Rendering…"
            let r = try await MediaEngineV1().render(inputs,
                        progress: { p in Task { @MainActor in self.progress = p } },
                        shouldCancel: { self.cancelFlag })
            await MainActor.run {
                self.result = r
                self.player = AVPlayer(url: r.url)
                self.status = "Done: \(r.relativePath)"
            }
        } catch {
            await MainActor.run { self.status = "Failed: \(error)" }
        }
        await MainActor.run { self.rendering = false }
    }
}
#endif

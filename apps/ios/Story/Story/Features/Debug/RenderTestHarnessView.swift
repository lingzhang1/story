#if DEBUG
import AVKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// RenderTestHarnessView — DEBUG-ONLY internal developer surface (Milestone R-b §3 / Case G). NOT the consumer
// Create My Story flow and NOT compiled into Release. Lets the owner render EITHER a known-valid EditPlan/2
// fixture (no network) OR a REAL plan from the deployed Edit Planner (/v1/edit-plan, Case G) over an existing
// Story's local Moments, then play the MP4, inspect it, and save/share. No Epidemic; NO-MUSIC mode only;
// optional LOCAL test soundtrack only. No provider credentials ever reach the device.
struct RenderTestHarnessView: View {
    @Bindable var story: StoryModel
    @Environment(\.modelContext) private var modelContext

    @State private var media: [MomentMedia] = []
    @State private var status: String = "Idle"
    @State private var progress: Float = 0
    @State private var player: AVPlayer?
    @State private var result: RenderResult?
    @State private var rendering = false
    @State private var useRealPlan = false
    @State private var cancelFlag = false
    @State private var diag: Diagnostics?
    @State private var fixtureCase: FixtureCase = .montage

    enum FixtureCase: String, CaseIterable, Identifiable {
        case montage = "Montage (A)"
        case speed = "Speed 0.5x/2x (D)"
        case missing = "Missing Moment (F)"
        var id: String { rawValue }
    }

    // Case G diagnostics (DEBUG-only; no raw private video, no API keys, no personal paths).
    struct Diagnostics {
        var mode: String = "—"                 // "fixture (no network)" | "real /v1/edit-plan (no music)"
        var model: String = "—"
        var planLatencyMs: Int?
        var selectedMoments: Int = 0
        var excludedMoments: Int = 0
        var segments: Int = 0
        var requestedDuration: Double?
        var plannedDuration: Double?
        var renderedDuration: Double?
        var renderLatencyMs: Int?
        var outputSize: String = "—"
        var feasible: Bool?
        var validationErrors: [String] = []
        var musicMode: String = "no music (Case G)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Story") {
                    Text(story.title).font(.headline)
                    Text("\(media.count) resolvable Moments").foregroundStyle(.secondary)
                }
                Section("Plan source") {
                    Toggle("Use real Edit Planner (/v1/edit-plan)", isOn: $useRealPlan)
                    Text(useRealPlan
                         ? "Real AI plan — Opus 4.6 via the deployed backend, no-music mode"
                         : "Deterministic fixture (no network)")
                        .font(.caption).foregroundStyle(.secondary)
                    if !useRealPlan {
                        Picker("Fixture case", selection: $fixtureCase) {
                            ForEach(FixtureCase.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu)
                        if fixtureCase == .missing {
                            Text("Expect a clear missingMoment error and NO output (Case F).")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                Section("Render") {
                    Button(rendering ? "Working…" : (useRealPlan ? "Generate AI EditPlan + Render" : "Render Test Story")) {
                        Task { useRealPlan ? await renderRealPlan() : await renderFixture() }
                    }
                    .disabled(rendering || media.isEmpty)
                    if rendering {
                        ProgressView(value: progress)
                        Button("Cancel", role: .destructive) { cancelFlag = true }
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if let d = diag { diagnosticsSection(d) }
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

    @ViewBuilder
    private func diagnosticsSection(_ d: Diagnostics) -> some View {
        Section("Diagnostics") {
            row("Mode", d.mode)
            row("Planner model", d.model)
            if let ms = d.planLatencyMs { row("Plan latency", "\(ms) ms") }
            row("Music", d.musicMode)
            row("Moments selected", "\(d.selectedMoments)" + (d.excludedMoments > 0 ? "  (\(d.excludedMoments) excluded)" : ""))
            row("Segments", "\(d.segments)")
            if let r = d.requestedDuration { row("Requested duration", String(format: "%.1fs", r)) }
            if let p = d.plannedDuration { row("Planned duration", String(format: "%.1fs", p)) }
            if let rd = d.renderedDuration { row("Rendered duration", String(format: "%.2fs", rd)) }
            if let ms = d.renderLatencyMs { row("Render latency", "\(ms) ms") }
            row("Output size", d.outputSize)
            if let f = d.feasible { row("Feasible", f ? "yes" : "no") }
            if !d.validationErrors.isEmpty {
                Text("Validation errors:").font(.caption).foregroundStyle(.red)
                ForEach(d.validationErrors, id: \.self) { Text("• \($0)").font(.caption2).foregroundStyle(.red) }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).multilineTextAlignment(.trailing) }
            .font(.caption)
    }

    // MARK: - Fixture path (no network)

    private func renderFixture() async {
        rendering = true; cancelFlag = false; progress = 0; status = "Building fixture plan…"; result = nil; player = nil
        var d = Diagnostics(); d.mode = "fixture: \(fixtureCase.rawValue)"; d.model = "none (deterministic)"
        let plan: EditPlanV2
        switch fixtureCase {
        case .montage: plan = DebugEditPlanFixture.montage(media: media)
        case .speed:   plan = DebugEditPlanFixture.speedCases(media: media)
        case .missing: plan = DebugEditPlanFixture.missingMoment(media: media)
        }
        d.selectedMoments = media.count; d.segments = plan.segments.count; d.plannedDuration = plan.targetDurationSeconds
        diag = d
        // Case F deliberately includes an unresolvable id: do NOT pre-filter it — the engine must hard-fail.
        await render(plan: plan, resolver: MomentResolver.urlResolver(for: media), diag: &d)
    }

    // MARK: - Real Edit Planner path (Case G)

    private func renderRealPlan() async {
        rendering = true; cancelFlag = false; progress = 0; status = "Requesting AI EditPlan…"; result = nil; player = nil
        var d = Diagnostics(); d.mode = "real /v1/edit-plan (no music)"; d.model = "us.anthropic.claude-opus-4-6-v1"
        diag = d
        do {
            let build = try EditPlanRequestBuilder.build(story: story, context: modelContext)
            d.selectedMoments = build.includedMedia.count
            d.excludedMoments = build.excludedMomentIds.count
            if case let .object(ci) = build.request.creativeIntent,
               case let .number(t)? = ci["target_duration_seconds"] { d.requestedDuration = t }
            diag = d

            let t0 = Date()
            let plan = try await EditPlannerService().plan(build.request)
            d.planLatencyMs = Int(Date().timeIntervalSince(t0) * 1000)
            d.segments = plan.segments.count
            d.plannedDuration = plan.targetDurationSeconds
            d.feasible = plan.feasible
            // Local executability pre-check (every asset_id resolves) — invalid plans never reach the engine.
            let resolver = MomentResolver.urlResolver(for: build.includedMedia)
            let unresolved = plan.segments.map(\.assetId).filter { resolver($0) == nil }
            if !unresolved.isEmpty {
                d.validationErrors = unresolved.map { "segment asset_id \($0) has no local file" }
                diag = d; status = "Plan references unavailable Moments — not rendered."; rendering = false; return
            }
            diag = d
            await render(plan: plan, resolver: resolver, diag: &d)
        } catch {
            d.validationErrors = [String(describing: (error as? LocalizedError)?.errorDescription ?? "\(error)")]
            diag = d; status = "Edit Planner failed: \(error)"; rendering = false
        }
    }

    // MARK: - Shared render

    private func render(plan: EditPlanV2, resolver: @escaping (String) -> URL?, diag d: inout Diagnostics) async {
        let inputs = MediaEngineInputs(
            plan: plan,
            resolveMomentURL: resolver,
            soundtrackURL: nil,                      // no soundtrack (no Epidemic / Case G no-music)
            musicAnalysis: nil,
            soundtrackRole: "supportive", nativeAudioPriority: "selective")
        let snapshot = d
        do {
            status = "Rendering…"
            let t0 = Date()
            let r = try await MediaEngineV1().render(inputs,
                        progress: { p in Task { @MainActor in self.progress = p } },
                        shouldCancel: { self.cancelFlag })
            await MainActor.run {
                var dd = snapshot
                dd.renderLatencyMs = Int(Date().timeIntervalSince(t0) * 1000)
                dd.renderedDuration = r.durationSeconds
                dd.outputSize = String(format: "%.0f×%.0f", r.renderSize.width, r.renderSize.height)
                self.diag = dd
                self.result = r
                self.player = AVPlayer(url: r.url)
                self.status = "Done: \(r.relativePath)"
                self.rendering = false
            }
        } catch {
            await MainActor.run { self.status = "Render failed: \(error)"; self.rendering = false }
        }
    }
}
#endif

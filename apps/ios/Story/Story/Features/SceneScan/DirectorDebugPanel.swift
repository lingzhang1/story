import SwiftUI

#if DEBUG
// DirectorDebugPanel — DEBUG-only Director evaluation capture (C3B §8).
//
// After a Director recommendation, lets an internal tester mark the direction
// Good or Bad; Bad supports a lightweight failure classification. Each mark is
// written as a self-contained JSON case under the app's Documents/
// director_feedback/ so it can be pulled off the device and converted into a
// regression fixture (same shape as evals/story_director/*.fixture.json).
//
// Captures enough to REPRODUCE the case: CreativeIntent, SceneUnderstanding,
// Director output, model, prompt_version, schema_version, failure label. It
// does NOT retain scene frames (privacy — the scene descriptors are enough to
// re-run the Director offline).
//
// This is evaluation plumbing, NOT consumer UX: it compiles only in DEBUG.
struct DirectorDebugPanel: View {
    let story: StoryModel
    let creativeIntent: CreativeIntentContractDTO
    let scene: SceneUnderstandingContractDTO
    let output: DirectorOutputDTO
    let scanToRecommendationMs: Int?

    @State private var saved = false
    @State private var showBadOptions = false
    @State private var savedLabel: String?

    private let badLabels = [
        "generic", "doesn't use this scene", "doesn't match my intent",
        "hard to shoot", "physically infeasible", "unsafe", "confusing", "other"
    ]
    private let gold = Color(red: 0.83, green: 0.66, blue: 0.33)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(gold.opacity(0.3))
            Text("DEBUG · Director feedback")
                .font(.caption.bold()).foregroundStyle(gold.opacity(0.8))

            // Beat/shot count observation (§10) — surfaced for the tester.
            Text("beats \(output.plan.beats.count) · shots \(output.plan.shots.count) · decision \(output.decision.action.rawValue)"
                 + (scanToRecommendationMs.map { " · \($0)ms" } ?? ""))
                .font(.caption2.monospaced()).foregroundStyle(.gray)

            if saved {
                Text("Saved: \(savedLabel ?? "good") ✓")
                    .font(.caption).foregroundStyle(.green)
            } else {
                HStack(spacing: 12) {
                    Button("Good direction") { save(verdict: "good", label: nil) }
                        .font(.caption).tint(.green)
                    Button("Bad direction") { showBadOptions.toggle() }
                        .font(.caption).tint(.red)
                }
                .buttonStyle(.bordered)

                if showBadOptions {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)],
                              alignment: .leading, spacing: 6) {
                        ForEach(badLabels, id: \.self) { label in
                            Button(label) { save(verdict: "bad", label: label) }
                                .font(.caption2).buttonStyle(.bordered).tint(.red)
                        }
                    }
                }
            }
        }
    }

    private func save(verdict: String, label: String?) {
        let enc = StoryContractCoding.encoder()
        func obj(_ data: Data?) -> Any {
            guard let data, let o = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
            return o
        }
        let fixtureStub: [String: Any] = [
            "component": "story_director",
            "phase": "initialize",
            "verdict": verdict,
            "failure_label": label as Any,
            "model": "amazon.nova-pro-v1:0",
            "prompt_version": "story_director/v1",
            "schema_version": "story_director.envelope/1",
            "scan_to_recommendation_ms": scanToRecommendationMs as Any,
            "beat_count": output.plan.beats.count,
            "shot_count": output.plan.shots.count,
            "decision_action": output.decision.action.rawValue,
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            // reproduction inputs (NO scene frames retained)
            "inputs": [
                "creative_intent": obj(try? enc.encode(creativeIntent)),
                "scene_understanding": obj(try? enc.encode(scene))
            ],
            "director_output": obj(try? enc.encode(output))
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fixtureStub,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("director_feedback", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "dir_fb_\(Int(Date().timeIntervalSince1970))_\(verdict).json"
        try? data.write(to: dir.appendingPathComponent(name))
        savedLabel = label ?? verdict
        saved = true
    }
}
#endif

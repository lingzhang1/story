import SwiftUI
import SwiftData

// Shoot a Moment (Milestone C3B) — the entry into the real DIRECT flow.
//
// This view is now a thin launcher: it opens SceneScanFlowView, which owns the
// real pipeline (scan -> SceneUnderstanding -> Story Director -> ONE
// recommendation -> shot guidance -> real camera -> Moment). The old mock
// "Direction" text and the Director-bypassing "Open Camera" button are gone —
// capture always flows through the evaluated Director now.
struct ShootMomentView: View {
    @Bindable var story: StoryModel

    var body: some View {
        SceneScanFlowView(story: story)
    }
}

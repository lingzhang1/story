import SwiftUI
import SwiftData

// Shoot a Moment — the primary in-Story capture entry.
//
// Capture Anywhere (Figma V0.2.2) unifies this with Home capture: it now opens
// the SAME continuous camera (ContinuousCaptureView) as Home, so the camera is
// usable IMMEDIATELY without first completing a scene scan. The only difference
// is CaptureContext.story(story): each saved clip is a global Moment AND gets
// exactly one StoryMomentLink to this Story (capture order preserved).
//
// AI Ideas remain available as an OPTIONAL action inside the camera (the "Get an
// AI shot idea" pill), using this Story's CreativeIntent/Guide — the scan +
// Director functionality is reused, not removed. The scan-FIRST flow
// (SceneScanFlowView) is still used by the opportunity-driven path (Story Idea
// "Show me" / Guide possibility "Shoot") in StoryHomeView.
struct ShootMomentView: View {
    @Bindable var story: StoryModel

    var body: some View {
        ContinuousCaptureView(captureContext: .story(story))
    }
}

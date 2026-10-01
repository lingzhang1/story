# Story — iOS App (Milestone A walking skeleton)

Native SwiftUI + SwiftData + AVFoundation app implementing the first
vertical slice: Start a Story → Creative Direction → create Story →
Shoot a Moment (real camera) → Create My Story (mock output), all
persisted locally and surviving app relaunch.

The Xcode project is committed. Standard Xcode layout (the two-level
`Story/Story/` nesting is normal and expected — the outer folder is the
project container, the inner one is the app target's source group):

```
apps/ios/
├── README.md
└── Story/                      ← Xcode project container
    ├── Story.xcodeproj
    ├── Story/                   ← app target sources
    │   ├── App/        StoryApp.swift (@main, ModelContainer)
    │   ├── Data/       Persistence (SwiftData @Model), Repositories
    │   ├── Domain/     Engines (protocols + mocks), UseCases
    │   ├── Features/   Home, StartStory, StoryHome, Capture
    │   ├── Media/      Camera (AVFoundation), Playback (MediaStore)
    │   └── Assets.xcassets
    ├── StoryTests/              ← unit tests (StoryFoundationTests.swift)
    └── StoryUITests/            ← empty UI-test scaffold (unused)
```

## Open & run

1. Open `apps/ios/Story/Story.xcodeproj` in **Xcode 16.4+**.
2. **Signing & Capabilities** (select the top `Story` project → `Story`
   target → the tab): check **Automatically manage signing**, pick your
   **Team** (a free personal Apple ID works), set a unique **Bundle
   Identifier** (e.g. `com.<you>.story`).
3. **Info** tab → confirm these three keys exist (the app crashes on
   capture without the camera key):
   - `Privacy - Camera Usage Description`
   - `Privacy - Microphone Usage Description`
   - `Privacy - Photo Library Usage Description`
4. **Simulator** validates everything EXCEPT real-camera capture (no
   camera in the Simulator). **Physical iPhone** is required for capture.

## First run on a physical device

- Plug in → trust the Mac → select the device as the run destination → ⌘R.
- First launch: iOS blocks the untrusted dev cert. On the phone,
  **Settings → General → VPN & Device Management → [your Apple ID] →
  Trust**, then ⌘R again.
- **Free Apple ID installs expire after 7 days** — the app stays on the
  home screen but won't launch until you re-run from Xcode (re-signs for
  another 7 days). Your local Stories/Moments/videos survive the re-sign.
  A paid Apple Developer account removes the 7-day limit.

## Acceptance flow (physical iPhone)

1. **Start a Story** → title + a sentence → **Create Story**.
2. **Shoot a Moment** → read the mock direction → **Open Camera** → allow
   camera + mic → **Record** a few seconds → **Stop**.
3. Confirm the Moment appears on Story Home with a playable thumbnail.
4. **Create My Story** → a Generated Output row appears; the Story status
   stays **active** (Create ≠ Complete).
5. **Kill the app** → **relaunch** → confirm the Story, Moment (video
   still plays), and Generated Output metadata all survived.

## Backend (optional for this slice)

The slice persists everything locally and does not require the backend.
To exercise the deployed dev API, set its base URL (the `cdk deploy`
output `ApiServiceUrl`) in a build setting / small `Config.swift`; a
networking client is not part of the offline slice.

## Architecture notes

- **UI depends on protocols** (`StoryEngineProtocol`,
  `DirectorEngineProtocol`, `EditEngineProtocol`), never on the `Mock*`
  classes — swap in AI later with no view changes.
- **Local-first media**: the video original is written to
  `<Documents>/media/<uuid>.mov`. SwiftData stores only the **relative
  path**, never the blob and never a cloud URL. `MediaStore` is the only
  place that resolves paths to URLs.
- **Persistence ≠ domain ≠ DTO**: `Data/Persistence/Models.swift` are the
  SwiftData models; the engine value types in `Domain/Engines` are domain
  shapes; API DTOs live in the backend `contracts/`.
- No real AI, no Bedrock, no upload of originals.

## Not yet done (intentional, later milestones)

- **DesignSystem pass**: the UI is a functional skeleton, not yet styled
  to the Figma reference (Fraunces display type, gold `#d4a853`, warm
  white). This is a separate view-layer pass tracked for later.
- Real AI engines, scene understanding, music, real EditPlan — deferred
  per the build plan.

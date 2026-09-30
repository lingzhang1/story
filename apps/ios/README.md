# Story — iOS App (Milestone A walking skeleton)

Native SwiftUI + SwiftData + AVFoundation app implementing the first
vertical slice: Start a Story → Creative Direction → create Story →
Shoot a Moment (real camera) → Create My Story (mock output), all
persisted locally and surviving app relaunch.

These are **source files**, not a `.xcodeproj` yet (Xcode projects are
binary and best created on your machine). Follow the setup below once;
after that it's a normal Xcode app.

## 1. Create the Xcode project

1. Open **Xcode 16.4**. File → New → Project → **iOS → App**.
2. Product Name: `Story`. Interface: **SwiftUI**. Language: **Swift**.
   Storage: **SwiftData** (or None — we configure the container in code).
   Uncheck tests only if you want; we provide our own test file.
3. Save it so the project root is **this directory**
   (`apps/ios/`). You want the generated `Story.xcodeproj` to sit next to
   this README, with the `Story/` source folder as the app target group.
4. **Delete** Xcode's auto-generated `StoryApp.swift`,
   `ContentView.swift`, and `Item.swift` — our sources replace them.
5. Drag the existing `Story/` folder groups (App, Features, Domain,
   Data, Media, Support) into the app target. Drag `StoryTests/` into the
   test target. Choose **"Create groups"**, and ensure **Target
   Membership** is the app target for `Story/**` and the test target for
   `StoryTests/**`.

## 2. Deployment target & capabilities

- Set **Minimum Deployment: iOS 17.0** (SwiftData + `VideoPlayer` need 17+).
- Signing & Capabilities → select your **Team** (a free personal Apple ID
  works for 7-day on-device installs) → set a unique **Bundle Identifier**,
  e.g. `com.<you>.story`.

## 3. Info.plist keys (required for camera/mic)

Add these usage-description strings (Info tab, or Info.plist):

```
NSCameraUsageDescription       = "Story uses the camera to capture your moments."
NSMicrophoneUsageDescription   = "Story records audio with your video moments."
NSPhotoLibraryUsageDescription = "Story can import existing photos and videos." (future)
```

Missing `NSCameraUsageDescription`/`NSMicrophoneUsageDescription` will
**crash on capture**.

## 4. Point the app at the backend (optional for this slice)

The slice persists everything locally and does not require the backend to
create/persist a Story. When you want to exercise the deployed API, set
the App Runner base URL (from `cdk deploy` output `ApiServiceUrl`) in a
build setting or a small `Config.swift`; a networking client is not part
of the offline slice.

## 5. Run

- **Simulator** validates everything EXCEPT real camera capture (no
  camera in the Simulator): Story creation, persistence, navigation,
  Create My Story, and relaunch survival.
- **Physical iPhone** (required for the full DoD, item 11): plug in via
  USB → trust the Mac → select the device as run destination → ⌘R. On the
  phone, Settings → General → VPN & Device Management → trust your
  developer certificate if prompted.

## 6. The manual acceptance flow (physical iPhone)

1. Launch → **Start a Story** → type a title + a sentence of direction →
   **Create Story**.
2. On Story Home → **Shoot a Moment** → read the mock direction → **Open
   Camera** → **Record** a few seconds → **Stop**.
3. Confirm the Moment appears on Story Home with a playable thumbnail.
4. **Create My Story** → confirm a Generated Output row appears and the
   Story status stays **active** (Create ≠ Complete).
5. **Kill the app** (swipe up from app switcher) → **relaunch**.
6. Confirm: the Story still exists, the Moment still exists, the video
   **still plays**, and the Generated Output metadata is still there.

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

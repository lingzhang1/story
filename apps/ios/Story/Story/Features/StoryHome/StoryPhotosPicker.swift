import SwiftUI
import PhotosUI
import AVFoundation

// StoryPhotosPicker — frozen Figma "+ Add photos or videos" (add-to-Moments
// path). Wraps PhotosPicker, copies each picked VIDEO into MediaStore, and hands
// back (relativePath, durationSeconds) for StoryUseCases.addExistingMedia.
// Local/mechanical only — NO AI analysis (the analyze path stays disabled;
// ui-capability-matrix). C3.5.
//
// R-c.1 UX: copying picked videos out of the Photos library (often an iCloud
// download of the full file) can take seconds with NO visible change on Story
// Home, which read as "my import failed". `onProgress` reports the copy as it
// happens — started (0 of N), each item done (k of N), and finished — so the
// caller can show an honest, non-blocking "Adding your videos…" signal.

/// Progress of a running import, driven from the picker. `done`/`total` count
/// COPIED items; `failed` counts items that couldn't be read/copied (reported at
/// the end so the user is never told "done" when some silently dropped).
struct ImportProgress: Equatable {
    /// Operation-specific phase for honest, non-percentage feedback (Phase 5).
    enum Phase: Equatable {
        case preparing     // selection received; about to read the first item
        case importing     // copying items out of Photos into MediaStore
        case analyzing     // files persisted; Asset Understanding enqueued/running
    }
    var total: Int
    var done: Int
    var failed: Int
    var finished: Bool
    var phase: Phase = .importing
    static let idle = ImportProgress(total: 0, done: 0, failed: 0, finished: true, phase: .importing)
}

/// Pure mapping from import progress to an honest one-line banner. Extracted so it's unit-testable without a
/// SwiftUI host. Never says "done" while work is in flight, surfaces partial failures plainly, and names the
/// current operation (Preparing / Importing / Analyzing) WITHOUT fabricating a progress percentage.
enum StoryImportCopy {
    static func line(for p: ImportProgress) -> String {
        if !p.finished {
            switch p.phase {
            case .preparing:
                return "Preparing selected media…"
            case .importing:
                return p.total > 1 ? "Importing… (\(p.done) of \(p.total))" : "Importing your video…"
            case .analyzing:
                return "Analyzing moments…"
            }
        }
        // Finished.
        if p.done == 0 { return "Couldn't add those videos. Please try again." }
        if p.failed > 0 {
            return "Added \(p.done) · \(p.failed) couldn't be added."
        }
        return p.done > 1 ? "Added \(p.done) videos." : "Added your video."
    }
}

extension View {
    func photosPickerSheet(
        isPresented: Binding<Bool>,
        onProgress: @escaping (ImportProgress) -> Void = { _ in },
        onPicked: @escaping ([(path: String, duration: Double)]) -> Void
    ) -> some View {
        modifier(PhotosPickerModifier(isPresented: isPresented, onProgress: onProgress, onPicked: onPicked))
    }
}

private struct PhotosPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onProgress: (ImportProgress) -> Void
    let onPicked: ([(path: String, duration: Double)]) -> Void
    @State private var selection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $selection,
            // Per-session cap (you can reopen the picker to add more — each import APPENDS to the Story).
            // Raised from 10 so a larger shoot can be imported in one pass.
                          maxSelectionCount: 30, matching: .videos)
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                Task { await importAll(items) }
            }
    }

    private func importAll(_ items: [PhotosPickerItem]) async {
        let total = items.count
        // Phase 5: a brief "Preparing selected media…" before the first copy begins.
        await report(ImportProgress(total: total, done: 0, failed: 0, finished: false, phase: .preparing))

        var results: [(path: String, duration: Double)] = []
        var failed = 0
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                failed += 1
                await report(ImportProgress(total: total, done: results.count, failed: failed,
                                            finished: false, phase: .importing))
                continue
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mov")
            do {
                try data.write(to: tmp)
                let dur = CMTimeGetSeconds(AVURLAsset(url: tmp).duration)
                let rel = try MediaStore.shared.adoptCapturedFile(tempURL: tmp)
                results.append((rel, dur.isFinite ? dur : 0))
            } catch {
                failed += 1
            }
            await report(ImportProgress(total: total, done: results.count, failed: failed,
                                        finished: false, phase: .importing))
        }
        let final = results
        let finalFailed = failed
        await MainActor.run {
            selection = []
            if !final.isEmpty { onPicked(final) }
            onProgress(ImportProgress(total: total, done: final.count, failed: finalFailed,
                                      finished: true, phase: .importing))
        }
    }

    private func report(_ p: ImportProgress) async {
        await MainActor.run { onProgress(p) }
    }
}

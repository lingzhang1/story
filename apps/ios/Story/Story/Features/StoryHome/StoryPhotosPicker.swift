import SwiftUI
import PhotosUI
import AVFoundation

// StoryPhotosPicker — frozen Figma "+ Add photos or videos" (add-to-Moments
// path). Wraps PhotosPicker, copies each picked VIDEO into MediaStore, and hands
// back (relativePath, durationSeconds) for StoryUseCases.addExistingMedia.
// Local/mechanical only — NO AI analysis (the analyze path stays disabled;
// ui-capability-matrix). C3.5.
extension View {
    func photosPickerSheet(
        isPresented: Binding<Bool>,
        onPicked: @escaping ([(path: String, duration: Double)]) -> Void
    ) -> some View {
        modifier(PhotosPickerModifier(isPresented: isPresented, onPicked: onPicked))
    }
}

private struct PhotosPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPicked: ([(path: String, duration: Double)]) -> Void
    @State private var selection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $selection,
                          maxSelectionCount: 10, matching: .videos)
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                Task { await importAll(items) }
            }
    }

    private func importAll(_ items: [PhotosPickerItem]) async {
        var results: [(path: String, duration: Double)] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mov")
            do {
                try data.write(to: tmp)
                let dur = CMTimeGetSeconds(AVURLAsset(url: tmp).duration)
                let rel = try MediaStore.shared.adoptCapturedFile(tempURL: tmp)
                results.append((rel, dur.isFinite ? dur : 0))
            } catch { continue }
        }
        let final = results
        await MainActor.run {
            selection = []
            if !final.isEmpty { onPicked(final) }
        }
    }
}

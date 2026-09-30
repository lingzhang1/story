import SwiftUI
import SwiftData

// Shoot a Moment — shows the mock Director's guidance, then opens the
// real camera. On finish, the captured temp file is adopted into
// MediaStore and a Moment is created + persisted. Local-first: if
// persistence fails, the media file still exists on disk.

struct ShootMomentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var story: StoryModel

    @State private var showCamera = false
    @State private var suggestion: ShotSuggestion?

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context))
    }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.043).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text("Direction")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.83, green: 0.66, blue: 0.33))
                Text(suggestion?.guidance ?? "…")
                    .font(.system(size: 24, weight: .light, design: .serif))
                    .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91))

                Spacer()

                Button { showCamera = true } label: {
                    Text("Open Camera")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(red: 0.83, green: 0.66, blue: 0.33))
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Button("Cancel") { dismiss() }
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .onAppear { suggestion = useCases.directNextMoment(for: story) }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(
                onFinish: { tempURL, duration in
                    handleCapture(tempURL: tempURL, duration: duration)
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
    }

    private func handleCapture(tempURL: URL, duration: Double) {
        do {
            // 1. Persist media to disk FIRST (local-first guarantee).
            let relativePath = try MediaStore.shared.adoptCapturedFile(tempURL: tempURL)
            // 2. Then persist the Moment metadata.
            _ = try useCases.shootMoment(
                for: story, relativePath: relativePath, durationSeconds: duration)
            showCamera = false
            dismiss()
        } catch {
            // Media may still be on disk even if metadata write failed.
            print("Failed to save moment: \(error)")
            showCamera = false
        }
    }
}

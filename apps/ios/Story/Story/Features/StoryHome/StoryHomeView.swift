import SwiftUI
import SwiftData
import AVKit

// Story Home — the persistent hub for one Story. Shows its Moments,
// offers "Shoot a Moment" and "Create My Story". Status is shown but
// creating an output never changes it (Create != Complete).

struct StoryHomeView: View {
    @Environment(\.modelContext) private var context
    @Bindable var story: StoryModel
    @State private var showCapture = false
    @State private var lastOutputTitle: String?

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context))
    }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.043).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(story.intentSummary)
                        .font(.system(size: 20, weight: .light, design: .serif))
                        .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91))

                    // What Story understood from your direction (real model output).
                    IntentChips(story: story)

                    Text(story.status.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.gray)

                    Text("Moments (\(story.moments.count))")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.83, green: 0.66, blue: 0.33))

                    if story.moments.isEmpty {
                        Text("No moments yet. Shoot one to begin.")
                            .foregroundStyle(.gray)
                    } else {
                        ForEach(story.moments.sorted(by: { $0.createdAt < $1.createdAt })) { moment in
                            MomentRow(moment: moment)
                        }
                    }

                    Button { showCapture = true } label: {
                        actionLabel("Shoot a Moment", filled: true)
                    }

                    Button { createOutput() } label: {
                        actionLabel("Create My Story", filled: false)
                    }
                    .disabled(story.moments.isEmpty)

                    if !story.generatedOutputs.isEmpty {
                        Text("Generated Outputs (\(story.generatedOutputs.count))")
                            .font(.headline)
                            .foregroundStyle(Color(red: 0.83, green: 0.66, blue: 0.33))
                        ForEach(story.generatedOutputs.sorted(by: { $0.createdAt < $1.createdAt })) { output in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(output.title).foregroundStyle(.white)
                                Text(String(format: "%.0fs · %d moments", output.durationSeconds, output.momentIds.count))
                                    .font(.caption).foregroundStyle(.gray)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(red: 0.09, green: 0.09, blue: 0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    Spacer()
                }
                .padding(20)
            }
        }
        .navigationTitle(story.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCapture) {
            ShootMomentView(story: story)
        }
    }

    private func actionLabel(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(filled ? Color(red: 0.83, green: 0.66, blue: 0.33) : Color.clear)
            .foregroundStyle(filled ? .black : Color(red: 0.83, green: 0.66, blue: 0.33))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.83, green: 0.66, blue: 0.33), lineWidth: filled ? 0 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func createOutput() {
        do { _ = try useCases.createStoryOutput(for: story) }
        catch { print("Failed to create output: \(error)") }
    }
}

// Surfaces what the real model understood from the user's direction.
// Creative Intent interprets WHAT the user wants; it does NOT yet generate
// shot ideas — that is Scene Understanding + Story Director (next milestone).
private struct IntentChips: View {
    @Bindable var story: StoryModel
    private let gold = Color(red: 0.83, green: 0.66, blue: 0.33)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Story understood")
                .font(.caption).foregroundStyle(gold)
            FlowChips(items: labeledChips)
            if let subject = story.intentSubject, !subject.isEmpty {
                Text("About: \(subject)").font(.caption2).foregroundStyle(.gray)
            }
            if !story.intentConstraints.isEmpty {
                Text("Keep in mind: " + story.intentConstraints.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var labeledChips: [String] {
        var chips: [String] = []
        chips += story.intentDesiredFeeling
        chips += story.intentEmphasis.map { "✦ \($0)" }
        if let p = story.intentPace, !p.isEmpty { chips.append("pace: \(p)") }
        if let d = story.intentTargetDurationSeconds { chips.append("\(Int(d))s") }
        if chips.isEmpty { chips = ["(minimal — add more direction for a richer read)"] }
        return chips
    }
}

// Simple wrapping chip row.
private struct FlowChips: View {
    let items: [String]
    private let gold = Color(red: 0.83, green: 0.66, blue: 0.33)
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(gold.opacity(0.15))
                    .foregroundStyle(gold)
                    .clipShape(Capsule())
            }
        }
    }
}

private struct MomentRow: View {
    let moment: MomentModel

    var body: some View {
        HStack(spacing: 12) {
            if let asset = moment.asset,
               MediaStore.shared.fileExists(relativePath: asset.relativePath) {
                let url = MediaStore.shared.absoluteURL(for: asset.relativePath)
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(width: 120, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 120, height: 80)
                    .overlay(Text("missing").font(.caption2).foregroundStyle(.gray))
            }
            VStack(alignment: .leading) {
                Text(moment.source.rawValue).foregroundStyle(.white)
                if let asset = moment.asset {
                    Text(String(format: "%.1fs", asset.durationSeconds))
                        .font(.caption).foregroundStyle(.gray)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

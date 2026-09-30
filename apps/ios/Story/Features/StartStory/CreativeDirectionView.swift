import SwiftUI
import SwiftData

// Creative Direction — the user describes what they want to make in free
// text. The mock StoryEngine derives a CreativeIntent; we create + persist
// the Story and navigate to its Story Home.

struct CreativeDirectionView: View {
    @Environment(\.modelContext) private var context
    @State private var title: String = ""
    @State private var direction: String = ""
    @State private var createdStory: StoryModel?

    private var useCases: StoryUseCases {
        StoryUseCases(repository: StoryRepository(context: context))
    }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.043).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Text("What do you want to make?")
                    .font(.system(size: 28, weight: .light, design: .serif))
                    .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91))

                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(Color(red: 0.09, green: 0.09, blue: 0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)

                ZStack(alignment: .topLeading) {
                    if direction.isEmpty {
                        Text("e.g. A weekend hiking the Tour du Mont Blanc with friends…")
                            .foregroundStyle(.gray)
                            .padding(18)
                    }
                    TextEditor(text: $direction)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .foregroundStyle(.white)
                }
                .frame(height: 140)
                .background(Color(red: 0.09, green: 0.09, blue: 0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    createStory()
                } label: {
                    Text("Create Story")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(red: 0.83, green: 0.66, blue: 0.33))
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                          || direction.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding(20)
        }
        .navigationTitle("Start a Story")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $createdStory) { story in
            StoryHomeView(story: story)
        }
    }

    private func createStory() {
        do {
            createdStory = try useCases.startStory(title: title, direction: direction)
        } catch {
            // Local-first: a failure here never loses captured media (none yet).
            print("Failed to create story: \(error)")
        }
    }
}

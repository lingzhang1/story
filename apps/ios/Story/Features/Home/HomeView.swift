import SwiftUI
import SwiftData

// Home — the three entry points (spec production §Home). For Milestone A
// only "Start a Story" is wired; the others are visible but disabled.

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StoryModel.createdAt, order: .reverse) private var stories: [StoryModel]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.043).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 24) {
                    Text("Story")
                        .font(.system(size: 40, weight: .light, design: .serif))
                        .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91))
                        .padding(.top, 40)

                    VStack(spacing: 14) {
                        NavigationLink {
                            CreativeDirectionView()
                        } label: {
                            EntryCard(title: "Start a Story",
                                      subtitle: "A trip, an event, something that unfolds over time",
                                      enabled: true)
                        }
                        EntryCard(title: "Create Now",
                                  subtitle: "Make something good, right here, right now",
                                  enabled: false)
                        EntryCard(title: "Use Existing Photos/Videos",
                                  subtitle: "Turn media you already have into a story",
                                  enabled: false)
                    }

                    if !stories.isEmpty {
                        Text("Your Stories")
                            .font(.headline)
                            .foregroundStyle(Color(red: 0.83, green: 0.66, blue: 0.33))
                            .padding(.top, 8)
                        List(stories) { story in
                            NavigationLink {
                                StoryHomeView(story: story)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(story.title).foregroundStyle(.white)
                                    Text("\(story.status.rawValue) · \(story.moments.count) moments · \(story.generatedOutputs.count) outputs")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }
                            }
                            .listRowBackground(Color(red: 0.09, green: 0.09, blue: 0.1))
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

private struct EntryCard: View {
    let title: String
    let subtitle: String
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(enabled ? Color(red: 0.96, green: 0.94, blue: 0.91) : .gray)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(enabled ? 1 : 0.5)
    }
}

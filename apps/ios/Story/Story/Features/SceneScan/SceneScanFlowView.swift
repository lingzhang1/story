import SwiftUI

// SceneScanFlowView — the Scene Scan user flow (Milestone C2).
//
// intro -> scanning (live capture) -> analyzing -> success | failed.
// It PRESENTS the scene observations the backend returns; it does NOT create
// Moments, write SwiftData, or suggest shot ideas/directions. On failure it
// shows the error and offers retry — it NEVER fabricates observations.
struct SceneScanFlowView: View {
    enum ScanState {
        case intro
        case scanning
        case analyzing
        case success(SceneUnderstandingContractDTO)
        case failed(String)
    }

    // One capture session identity per flow instance.
    let captureSessionId: UUID = UUID()
    let storyId: UUID?
    let mode: String = "shoot_moment"

    @Environment(\.dismiss) private var dismiss
    @State private var state: ScanState = .intro

    private let service = SceneUnderstandingService()

    private let bg = Color(red: 0.04, green: 0.04, blue: 0.043)
    private let gold = Color(red: 0.83, green: 0.66, blue: 0.33)
    private let ink = Color(red: 0.96, green: 0.94, blue: 0.91)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            switch state {
            case .intro:     introView
            case .scanning:  Color.clear
            case .analyzing: analyzingView
            case .success(let dto): successView(dto)
            case .failed(let message): failedView(message)
            }
        }
        .fullScreenCover(isPresented: scanningBinding) {
            SceneScanView(
                onFrames: { frames in handleFrames(frames) },
                onCancel: { state = .intro }
            )
            .ignoresSafeArea()
        }
    }

    private var scanningBinding: Binding<Bool> {
        Binding(
            get: { if case .scanning = state { return true } else { return false } },
            set: { presenting in
                if !presenting, case .scanning = state { state = .intro }
            }
        )
    }

    // MARK: - intro

    private var introView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Text("Show me what's around you")
                .font(.system(size: 32, weight: .light, design: .serif))
                .foregroundStyle(ink)
            Text("Slowly move your phone around the scene")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(ink.opacity(0.7))
            Spacer()
            Button { state = .scanning } label: {
                Text("Start Scan")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(gold)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Button("Cancel") { dismiss() }
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
    }

    // MARK: - analyzing

    private var analyzingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .tint(gold)
                .scaleEffect(1.4)
            Text("Reading the scene…")
                .font(.system(size: 20, weight: .light, design: .serif))
                .foregroundStyle(ink)
        }
    }

    // MARK: - success (read-only observations)

    private func successView(_ dto: SceneUnderstandingContractDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(dto.summary)
                    .font(.system(size: 22, weight: .light, design: .serif))
                    .foregroundStyle(ink)

                if !dto.environmentTags.isEmpty {
                    section("Environment") {
                        chipFlow(dto.environmentTags)
                    }
                }

                if !dto.subjects.isEmpty {
                    section("Subjects") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(dto.subjects.enumerated()), id: \.offset) { _, subject in
                                HStack(spacing: 8) {
                                    chip(subject.label)
                                    if let prominence = subject.prominence {
                                        Text(prominence.rawValue)
                                            .font(.caption)
                                            .foregroundStyle(ink.opacity(0.6))
                                    }
                                    if let note = subject.note {
                                        Text(note)
                                            .font(.caption)
                                            .foregroundStyle(ink.opacity(0.6))
                                    }
                                }
                            }
                        }
                    }
                }

                if let operatorSpace = dto.operatorSpace {
                    section("Operator space") { chip(operatorSpace.rawValue) }
                }

                if let lighting = dto.lighting {
                    section("Lighting") { chip(lighting) }
                }

                if !dto.motionOpportunities.isEmpty {
                    section("Motion opportunities") {
                        bullets(dto.motionOpportunities)
                    }
                }

                if !dto.compositionOpportunities.isEmpty {
                    section("Composition opportunities") {
                        bullets(dto.compositionOpportunities)
                    }
                }

                if !dto.constraints.isEmpty {
                    section("Constraints") {
                        bullets(dto.constraints)
                    }
                }

                VStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(gold)
                            .foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button("Rescan") { state = .intro }
                        .foregroundStyle(gold)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
    }

    // MARK: - failed

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text(message)
                .font(.system(size: 20, weight: .light, design: .serif))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
            Spacer()
            Button { state = .intro } label: {
                Text("Try Again")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(gold)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Button("Cancel") { dismiss() }
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
    }

    // MARK: - frame handling

    private func handleFrames(_ frames: [UIImage]) {
        state = .analyzing
        Task {
            do {
                let selected = SceneFrameProcessor.select(from: frames, max: 5)
                let dto = try await service.analyze(
                    frames: selected,
                    captureSessionId: captureSessionId,
                    mode: mode,
                    storyId: storyId)
                await MainActor.run { state = .success(dto) }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Something went wrong. Please try again."
                await MainActor.run { state = .failed(message) }
            }
        }
    }

    // MARK: - presentation helpers

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(gold)
            content()
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(gold.opacity(0.15))
            .foregroundStyle(gold)
            .clipShape(Capsule())
    }

    private func chipFlow(_ items: [String]) -> some View {
        // Simple wrapping row of chips.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                chip(item)
            }
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(gold)
                    Text(item)
                        .font(.body)
                        .foregroundStyle(ink.opacity(0.85))
                }
            }
        }
    }
}

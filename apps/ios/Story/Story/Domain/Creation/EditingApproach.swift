import Foundation

// EditingApproach — the user-visible creative approach chosen on the Customize Your Story screen (MVP UX).
//
// Two approaches, surfaced from the editing experiments:
//   .storytelling  — A1 rich-TEXT planning via /v1/edit-plan (faster; "uses video descriptions").
//   .visualFirst   — A1 text + contact-sheet VISUAL evidence via /v1/edit-plan-mm (more analysis; may take longer).
//
// This is a PRODUCT preference, independent of Story Length and Sound. It is persisted on StoryModel and
// routed by StoryCreationCoordinator. It carries NO model names / endpoints / tokens — the user-facing copy is
// deliberately non-technical. Visual-first is only OFFERED when StoryMultimodalPlanning.enabled is true (the
// deployment safety gate): we never present an option we cannot honor. Even when offered, Visual-first keeps
// the existing graceful text-only fallback, so a Story is never failed when a valid text-only edit is possible.
enum EditingApproach: String, CaseIterable {
    case storytelling = "storytelling"
    case visualFirst  = "visual_first"

    /// Default for a new Story and for any existing Story with no stored preference (backward compatible):
    /// storytelling = the frozen, device-verified text-only path.
    static let `default`: EditingApproach = .storytelling

    /// Tolerant decode of a persisted raw value — unknown / nil => the safe default (migration-safe).
    static func fromRaw(_ raw: String?) -> EditingApproach {
        guard let raw, let v = EditingApproach(rawValue: raw) else { return .default }
        return v
    }

    /// Does this approach require the multimodal (contact-sheet) planning path?
    var requiresMultimodal: Bool { self == .visualFirst }

    // MARK: - User-facing copy (NON-technical: no model/endpoint/token jargon)

    var title: String {
        switch self {
        case .storytelling: return "Storytelling"
        case .visualFirst:  return "Visual-first"
        }
    }

    var detail: String {
        switch self {
        case .storytelling:
            return "Build a meaningful story from your moments, with a clear beginning, progression, and ending."
        case .visualFirst:
            return "Look across your footage to find striking visuals, expressive moments, and compelling sequences."
        }
    }

    /// Secondary supporting line (speed / effort hint).
    var supporting: String {
        switch self {
        case .storytelling: return "Faster · Uses video descriptions"
        case .visualFirst:  return "More visual analysis · May take longer"
        }
    }

    var icon: String {
        switch self {
        case .storytelling: return "book"
        case .visualFirst:  return "film"
        }
    }
}

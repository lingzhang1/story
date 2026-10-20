import Foundation

// R1 — Account isolation visibility rules, CENTRALIZED so every surface (Home, Stories list, Moments library,
// navigation, pending-op recovery) applies the SAME predicate and no call site re-invents it. These are the
// device-side visibility scope (a mirror of the server-authoritative ownership); the backend remains the
// authority on every protected request.
//
// Owner decisions encoded here (architecture review §7, Decisions 1–2):
//   • A STORY is always account-owned → visible ONLY to its owner account.
//   • A MOMENT is LOCAL-ONLY (shared across every account on the device) until it is uploaded and account-owned
//     (a FUTURE increment). So a Moment is visible iff it is local-only OR owned by the active account.
//   • An ANONYMOUS (signed-out) session sees NO Stories (there are none without an owner, post-R1) but DOES see
//     all local-only Moments.
//
// Pure functions (no SwiftData fetch) so they are trivially unit-testable and usable both as an in-memory
// filter over an unscoped @Query (SwiftUI re-renders on auth change → switching accounts refreshes the view)
// and as the spec for the repository's scoped FetchDescriptor.
enum AccountScope {

    /// Can the active account (nil = signed out) SEE this Story?  Only its owner can.
    static func canSeeStory(ownerAccountId: String?, activeAccountId: String?) -> Bool {
        guard let active = activeAccountId else { return false }   // signed out → no Stories
        return ownerAccountId == active
    }

    /// Can the active account SEE this Moment?  Local-only Moments are shared with everyone; an owned Moment
    /// only with its owner. `isLocalOnly` comes from MomentModel.isLocalOnly (ownerAccountId == nil && local_only).
    static func canSeeMoment(ownerAccountId: String?, isLocalOnly: Bool, activeAccountId: String?) -> Bool {
        if isLocalOnly { return true }                              // shared device-local library
        guard let active = activeAccountId else { return false }    // owned Moment + signed out → hidden
        return ownerAccountId == active
    }
}

#if canImport(SwiftData)
import SwiftData

extension Array where Element == StoryModel {
    /// Stories visible to the active account (in-memory filter; preserves input order).
    @MainActor func visible(to activeAccountId: String?) -> [StoryModel] {
        filter { AccountScope.canSeeStory(ownerAccountId: $0.ownerAccountId, activeAccountId: activeAccountId) }
    }
}

extension Array where Element == MomentModel {
    /// Moments visible to the active account: all local-only (shared) + those owned by the active account.
    @MainActor func visible(to activeAccountId: String?) -> [MomentModel] {
        filter { AccountScope.canSeeMoment(ownerAccountId: $0.ownerAccountId,
                                           isLocalOnly: $0.isLocalOnly,
                                           activeAccountId: activeAccountId) }
    }
}
#endif

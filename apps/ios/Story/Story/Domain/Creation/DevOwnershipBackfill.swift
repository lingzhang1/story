import Foundation
import SwiftData

// R1 Phase 3 — DEVELOPMENT-ONLY designated-account ownership backfill (owner Decision 3).
//
// We currently have exactly two internal testers and a device whose pre-R1 Stories were all created before any
// ownership existed (ownerAccountId == nil). The owner decided these legacy Stories belong to the account for
// `dearlingzhang@gmail.com`. This routine stamps them — ONCE, idempotently, non-destructively — so account
// isolation surfaces them only under that account.
//
// HARD CONSTRAINTS (all enforced below):
//   • DEV-ONLY: compiled behind #if DEBUG and additionally gated by a runtime dev check. It MUST NOT run in
//     production or any public-beta onboarding — there is no code path that calls it outside DEBUG.
//   • STABLE IDENTITY, NOT EMAIL: the owner is the account's resolved device identity (the Cognito `sub` the
//     app uses as `story_user_id`), NEVER the email string. We only RECOGNISE the designated account by its
//     known sub; we store the sub, not the email.
//   • IDEMPOTENT: only rewrites Stories whose ownerAccountId is nil. A second run is a no-op.
//   • NON-DESTRUCTIVE: never deletes/moves/duplicates any record or media file; never overwrites an explicit
//     (non-nil) owner.
//   • STORIES + STORY-DERIVED STATE ONLY: stamps Stories and their GeneratedOutputs (which carry their own
//     owner mirror). All other Story-derived records (guide/coverage/links/plans/pending) inherit ownership
//     THROUGH the Story, so they need no stamping.
//   • LOCAL-ONLY MOMENTS ARE LEFT SHARED: Moments are never touched (owner Decision 1 — local-only Moments stay
//     in the shared device-local library, visible to every account).
@MainActor
enum DevOwnershipBackfill {

    /// The designated account's device identity (= Cognito `sub` for dearlingzhang@gmail.com in dev pool
    /// us-east-1_AzfHOEdA5). This is the stable `story_user_id` the app uses on device, NOT the email.
    static let designatedAccountId = "94688428-50c1-7082-95e7-2c5a65a8c9d8"

    /// Run the one-time backfill IF the currently signed-in account is the designated one. Called from the
    /// first-sign-in hook. Safe to call repeatedly: it only stamps nil-owner Stories.
    /// Returns the number of Stories newly stamped (0 when nothing to do / not the designated account).
    @discardableResult
    static func runIfDesignatedAccount(signedInAccountId: String?, context: ModelContext) -> Int {
        #if DEBUG
        guard let account = signedInAccountId, account == designatedAccountId else { return 0 }
        return stampUnownedStories(to: account, context: context)
        #else
        // Production / public-beta: NEVER run. (Parameter unused by design.)
        _ = (signedInAccountId, context)
        return 0
        #endif
    }

    #if DEBUG
    /// Stamp every Story with a nil owner to `account`, inheriting onto its GeneratedOutputs. Idempotent +
    /// non-destructive: an explicit (non-nil) owner is never overwritten.
    private static func stampUnownedStories(to account: String, context: ModelContext) -> Int {
        let unowned = (try? context.fetch(FetchDescriptor<StoryModel>(
            predicate: #Predicate { $0.ownerAccountId == nil }))) ?? []
        guard !unowned.isEmpty else { return 0 }
        for story in unowned {
            story.ownerAccountId = account
            // Story-derived GeneratedOutputs inherit the owner (they carry their own mirror for scoped cleanup).
            for out in story.generatedOutputs where out.ownerAccountId == nil {
                out.ownerAccountId = account
            }
        }
        try? context.save()
        return unowned.count
    }
    #endif
}

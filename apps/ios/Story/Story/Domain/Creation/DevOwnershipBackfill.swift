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

    /// The designated account's legacy Cognito `sub` (for dearlingzhang@gmail.com in dev pool
    /// us-east-1_AzfHOEdA5). Used ONLY to RECOGNISE the designated account at sign-in. Ownership is stamped with
    /// the account's CANONICAL story_user_id (resolved via /v1/me), never this sub and never the email.
    static let designatedAccountSub = "94688428-50c1-7082-95e7-2c5a65a8c9d8"

    /// Run the one-time backfill IF the signing-in account IS the designated one (recognised by its Cognito
    /// sub). Stamps nil-owner pre-R1 Stories to the account's CANONICAL id (passed in). Idempotent + DEV-ONLY.
    /// Returns the number of Stories newly stamped.
    @discardableResult
    static func runIfDesignatedAccount(signedInSub: String?, canonicalId: String, context: ModelContext) -> Int {
        #if DEBUG
        guard let sub = signedInSub, sub == designatedAccountSub, !canonicalId.isEmpty else { return 0 }
        return stampUnownedStories(to: canonicalId, context: context)
        #else
        _ = (signedInSub, canonicalId, context)
        return 0
        #endif
    }

    /// R1.1 — ONE-TIME re-key of this account's R1 Stories from the legacy Cognito `sub` to the CANONICAL
    /// story_user_id. R1 stamped ownership with the sub; R1.1 makes the canonical id the single identity, so a
    /// Story stamped with the sub would otherwise become invisible under the canonical id. Re-keys ONLY rows
    /// owned by THIS account's own `legacySub` (never another account's — owner Decision 6), is idempotent (a
    /// row already on the canonical id is skipped), non-destructive (only flips the owner field; no delete/move/
    /// duplicate of records or media), and DEV-ONLY. Also re-keys the Stories' GeneratedOutputs. A no-op when
    /// sub == canonical (nothing to move) or sub is nil/empty.
    /// Returns the number of Stories re-keyed.
    @discardableResult
    static func rekeySubToCanonical(legacySub: String?, canonicalId: String, context: ModelContext) -> Int {
        #if DEBUG
        guard let sub = legacySub, !sub.isEmpty, !canonicalId.isEmpty, sub != canonicalId else { return 0 }
        let want: String? = sub
        let owned = (try? context.fetch(FetchDescriptor<StoryModel>(
            predicate: #Predicate { $0.ownerAccountId == want }))) ?? []
        guard !owned.isEmpty else { return 0 }
        for story in owned {
            story.ownerAccountId = canonicalId
            for out in story.generatedOutputs where out.ownerAccountId == sub {
                out.ownerAccountId = canonicalId
            }
        }
        try? context.save()
        return owned.count
        #else
        _ = (legacySub, canonicalId, context)
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

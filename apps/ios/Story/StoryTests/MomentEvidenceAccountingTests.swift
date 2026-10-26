import XCTest
import Foundation
@testable import Story

// Editorial Pipeline v2, P0 — MomentEvidenceAccounting reconciliation + the coordinator's census assembler.
// PURE logic (no SwiftData, no AVFoundation, no model, no network): every count is established from value
// inputs, so these run anywhere and prove the funnel reconciles and the per-reason classification is correct.
final class MomentEvidenceAccountingTests: XCTestCase {

    private func uuids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    private func census(linked: [UUID], noAU: [UUID], noDur: [UUID], notRender: [UUID],
                        eligible: [UUID]) -> EditPlanRequestBuilder.Build.EligibilityCensus {
        var c = EditPlanRequestBuilder.Build.EligibilityCensus()
        c.linkedCount = linked.count
        c.ineligibleNoAU = noAU
        c.ineligibleNoDuration = noDur
        c.ineligibleNotRenderable = notRender
        c.eligibleIds = eligible
        c.completedAUCount = linked.count - noAU.count
        c.positiveDurationCount = c.completedAUCount - noDur.count
        c.renderableCount = eligible.count
        return c
    }

    private func build(_ c: EditPlanRequestBuilder.Build.EligibilityCensus) -> EditPlanRequestBuilder.Build {
        // Minimal Build: only `eligibility` is read by the assembler.
        var b = EditPlanRequestBuilder.Build(
            request: EditPlanRequestDTO(
                storyId: UUID(), creativeIntentId: UUID(), creativeIntent: .object([:]),
                storyGuide: .object([:]), storyCoverage: .object([:]), moments: [],
                outputFormat: "vertical", musicPlan: nil, musicAssetId: nil, musicAnalysis: nil,
                soundPreference: nil, editorialMode: nil, revisionContext: nil),
            includedMedia: [], excludedMomentIds: [])
        b.eligibility = c
        return b
    }

    // MARK: - reconciliation

    func testReconcilesAllEligibleVisualFullyScanned() {
        // 5 linked, all eligible, all sheeted (visual-first).
        let ids = uuids(5)
        let c = census(linked: ids, noAU: [], noDur: [], notRender: [], eligible: ids)
        let sheeted = Set(ids.map { $0.uuidString.lowercased() })
        let a = StoryCreationCoordinator.assembleEvidenceAccounting(
            build: build(c), wantMultimodal: true, sheetedIds: sheeted,
            sheetMissReasons: [:], restoreUnavailableIds: [])
        XCTAssertTrue(a.reconciles)
        XCTAssertEqual(a.linkedCount, 5)
        XCTAssertEqual(a.eligibleCount, 5)
        XCTAssertEqual(a.sheetedCount, 5)
        XCTAssertEqual(a.missingSheetCount, 0)
    }

    func testReconcilesWithEligibilityDropsPerReason() {
        // 10 linked: 3 no-AU, 1 no-duration, 1 not-renderable -> 5 eligible.
        let noAU = uuids(3), noDur = uuids(1), notRender = uuids(1), elig = uuids(5)
        let linked = noAU + noDur + notRender + elig
        let c = census(linked: linked, noAU: noAU, noDur: noDur, notRender: notRender, eligible: elig)
        let sheeted = Set(elig.map { $0.uuidString.lowercased() })
        let a = StoryCreationCoordinator.assembleEvidenceAccounting(
            build: build(c), wantMultimodal: true, sheetedIds: sheeted,
            sheetMissReasons: [:], restoreUnavailableIds: [])
        XCTAssertTrue(a.reconciles)
        XCTAssertEqual(a.missingAUCount, 3)
        XCTAssertEqual(a.ineligibleNoDuration, 1)
        XCTAssertEqual(a.ineligibleNotRenderable, 1)
        XCTAssertEqual(a.eligibleCount, 5)
        XCTAssertEqual(a.ineligibleIds.count, 5)
    }

    // MARK: - sheet-miss classification (stages 7-10)

    func testTextOnlyRunClassifiesAllMissesAsNotRequested() {
        let ids = uuids(4)
        let c = census(linked: ids, noAU: [], noDur: [], notRender: [], eligible: ids)
        let a = StoryCreationCoordinator.assembleEvidenceAccounting(
            build: build(c), wantMultimodal: false, sheetedIds: [],
            sheetMissReasons: [:], restoreUnavailableIds: [])
        XCTAssertTrue(a.reconciles)
        XCTAssertEqual(a.sheetedCount, 0)
        XCTAssertEqual(a.missingSheetCount, 4)
        XCTAssertEqual(a.sheetMissByReason[SheetMissReason.notRequested.rawValue], 4)
        XCTAssertFalse(a.visualRequested)
    }

    func testVisualFirstPartialSheetsClassifyEachMissReason() {
        // 4 eligible: 1 sheeted, 1 extraction-empty, 1 unrestorable, 1 evicted-not-restored (no recorded reason).
        let sheetedId = UUID(), emptyId = UUID(), unrestId = UUID(), evictedId = UUID()
        let ids = [sheetedId, emptyId, unrestId, evictedId]
        let c = census(linked: ids, noAU: [], noDur: [], notRender: [], eligible: ids)
        let misses: [String: SheetMissReason] = [emptyId.uuidString.lowercased(): .extractionEmpty]
        let a = StoryCreationCoordinator.assembleEvidenceAccounting(
            build: build(c), wantMultimodal: true,
            sheetedIds: [sheetedId.uuidString.lowercased()],
            sheetMissReasons: misses,
            restoreUnavailableIds: [unrestId.uuidString.lowercased()])
        XCTAssertTrue(a.reconciles)
        XCTAssertEqual(a.sheetedCount, 1)
        XCTAssertEqual(a.missingSheetCount, 3)
        XCTAssertEqual(a.sheetMissByReason[SheetMissReason.extractionEmpty.rawValue], 1)
        XCTAssertEqual(a.sheetMissByReason[SheetMissReason.unrestorable.rawValue], 1)
        XCTAssertEqual(a.sheetMissByReason[SheetMissReason.evictedNotRestored.rawValue], 1)
        XCTAssertEqual(Set(a.eligibleWithoutSheetIds),
                       Set([emptyId, unrestId, evictedId].map { $0.uuidString.lowercased() }))
    }

    func testNoEligibleMomentsStillReconciles() {
        let noAU = uuids(3)
        let c = census(linked: noAU, noAU: noAU, noDur: [], notRender: [], eligible: [])
        let a = StoryCreationCoordinator.assembleEvidenceAccounting(
            build: build(c), wantMultimodal: true, sheetedIds: [],
            sheetMissReasons: [:], restoreUnavailableIds: [])
        XCTAssertTrue(a.reconciles)
        XCTAssertEqual(a.eligibleCount, 0)
        XCTAssertEqual(a.sheetedCount, 0)
        XCTAssertEqual(a.missingSheetCount, 0)
    }

    // MARK: - request serialization is privacy-safe

    func testRequestDictionaryCarriesOnlyCountsAndOpaqueIds() {
        let ids = uuids(2)
        let c = census(linked: ids, noAU: [], noDur: [], notRender: [], eligible: ids)
        let a = StoryCreationCoordinator.assembleEvidenceAccounting(
            build: build(c), wantMultimodal: true,
            sheetedIds: Set(ids.map { $0.uuidString.lowercased() }),
            sheetMissReasons: [:], restoreUnavailableIds: [])
        let d = a.asRequestDictionary()
        XCTAssertEqual(d["linked"] as? Int, 2)
        XCTAssertEqual(d["eligible"] as? Int, 2)
        XCTAssertEqual(d["reconciles"] as? Bool, true)
        // No raw media / prompt / transcript keys.
        for banned in ["media", "frames", "jpeg", "prompt", "transcript", "summary", "token"] {
            XCTAssertNil(d[banned], "evidence dict must not carry \(banned)")
        }
    }
}

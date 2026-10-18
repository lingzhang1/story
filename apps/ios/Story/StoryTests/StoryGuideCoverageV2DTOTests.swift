import XCTest
import SwiftData
@testable import Story

// E2-c DTO + Director entry-point tests (runnable in XCTest). Lifecycle/persistence tests live in
// StoryCoverageTests. These lock the wire shapes + the selected_opportunity construction.
final class StoryGuideCoverageV2DTOTests: XCTestCase {

    func testStoryGuideDTODecode() throws {
        let json = """
        {"schema_version":"story_guide/1","story_id":"\(UUID().uuidString)",
         "framing_summary":"For this Story: focus and progress.",
         "dimensions":[
           {"id":"dim_01","label":"Focus","purpose":"the concentration of practice",
            "capture_possibilities":[{"id":"dim_01_cp_01","label":"fingers on the fretboard","semantic_purpose":"the physical work"}]},
           {"id":"dim_02","label":"Breakthrough","purpose":"a moment it clicks","capture_possibilities":[]}]}
        """
        let g = try StoryContractCoding.decoder().decode(StoryGuideDTO.self, from: Data(json.utf8))
        XCTAssertEqual(g.dimensions.count, 2)
        XCTAssertEqual(g.dimensions[0].capturePossibilities[0].semanticPurpose, "the physical work")
        XCTAssertTrue(g.dimensions[1].capturePossibilities.isEmpty)   // zero-possibility dim is valid
    }

    func testCoverageV2StrongDimensionWithZeroRepresentedPossibilities() throws {
        // The load-bearing UI invariant: a dimension can be strong with NO represented possibilities.
        let json = """
        {"schema_version":"story_coverage/2","story_id":"\(UUID().uuidString)","story_guide_id":"g",
         "story_guide_version":"story_guide/1","moment_count":1,"pending_count":0,"source_understanding_ids":[],
         "dimension_coverage":[{"story_guide_dimension_id":"dim_01","state":"strong","note":null,
           "evidence_moment_ids":[],"represented_possibility_ids":[]}],
         "strengths":["Strong focus"],"redundancies":[],
         "sufficiency":{"status":"sufficient","reason":"enough"},"story_idea":null}
        """
        let c = try StoryContractCoding.decoder().decode(StoryCoverageV2DTO.self, from: Data(json.utf8))
        XCTAssertEqual(c.dimensionCoverage[0].state, .strong)
        XCTAssertTrue(c.dimensionCoverage[0].representedPossibilityIds.isEmpty)
        XCTAssertNil(c.storyIdea)                                     // null idea -> card hidden
    }

    func testCoverageV2SufficientWithIdeaIsValid() throws {
        // sufficiency and story_idea are INDEPENDENT: sufficient + an optional idea is allowed.
        let json = """
        {"schema_version":"story_coverage/2","story_id":"\(UUID().uuidString)","story_guide_id":"g",
         "story_guide_version":"story_guide/1","moment_count":3,"pending_count":0,"source_understanding_ids":[],
         "dimension_coverage":[],"strengths":[],"redundancies":[],
         "sufficiency":{"status":"sufficient","reason":"r"},
         "story_idea":{"title":"A moment of stillness","description":"a quiet beat","rationale":"rich internal","target_story_guide_dimension_id":"dim_02"}}
        """
        let c = try StoryContractCoding.decoder().decode(StoryCoverageV2DTO.self, from: Data(json.utf8))
        XCTAssertEqual(c.sufficiency.status, .sufficient)
        XCTAssertNotNil(c.storyIdea)                                 // sufficient + idea is VALID
        XCTAssertEqual(c.storyIdea?.targetStoryGuideDimensionId, "dim_02")
    }

    func testStoryIdeaShowMeBuildsSelectedOpportunity() {
        // Entry point A: Story Idea -> Show me.
        let idea = CoverageStoryIdeaV2DTO(title: "A moment together",
            description: "a natural moment of the two of you", rationale: "internal",
            targetStoryGuideDimensionId: "dim_03")
        let opp = SelectedOpportunityDTO(storyGuideDimensionId: idea.targetStoryGuideDimensionId,
            label: idea.title, purpose: idea.description, capturePossibilityLabel: nil)
        XCTAssertEqual(opp.label, "A moment together")
        XCTAssertEqual(opp.purpose, "a natural moment of the two of you")  // description, NOT rationale
        XCTAssertEqual(opp.storyGuideDimensionId, "dim_03")
        XCTAssertNil(opp.capturePossibilityLabel)
    }

    func testGuidePossibilityShootUsesSemanticPurposeThenFallsBack() {
        let dim = StoryGuideDimensionDTO(id: "dim_02", label: "Journey", purpose: "movement through the Alps",
            capturePossibilities: [])
        // with semantic_purpose -> use it
        let p1 = CapturePossibilityDTO(id: "dim_02_cp_01", label: "Boots moving through terrain",
            semanticPurpose: "forward progress through the rhythm of walking")
        let o1 = SelectedOpportunityDTO(storyGuideDimensionId: dim.id, label: p1.label,
            purpose: p1.semanticPurpose ?? dim.purpose, capturePossibilityLabel: p1.label)
        XCTAssertEqual(o1.purpose, "forward progress through the rhythm of walking")
        XCTAssertEqual(o1.capturePossibilityLabel, "Boots moving through terrain")
        // without semantic_purpose -> fall back to the dimension purpose
        let p2 = CapturePossibilityDTO(id: "dim_02_cp_02", label: "Side profile on the trail", semanticPurpose: nil)
        let o2 = SelectedOpportunityDTO(storyGuideDimensionId: dim.id, label: p2.label,
            purpose: p2.semanticPurpose ?? dim.purpose, capturePossibilityLabel: p2.label)
        XCTAssertEqual(o2.purpose, "movement through the Alps")        // dimension purpose fallback
    }

    func testSelectedOpportunityEncodesSnakeCase() throws {
        let opp = SelectedOpportunityDTO(storyGuideDimensionId: "dim_01", label: "L", purpose: "P",
            capturePossibilityLabel: "C")
        let data = try StoryContractCoding.encoder().encode(opp)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("story_guide_dimension_id"))
        XCTAssertTrue(s.contains("capture_possibility_label"))
    }
}

// Guide Reshoot -> continuous camera seeds the guide's OWN idea INSTANTLY (no network, no scan).
// Proves the fix for the ~5s delay: the idea card renders straight from the opportunity text the
// Story screen already holds, so Reshoot shows that exact idea with zero latency.
@MainActor
final class ContinuousCaptureSeedTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: StoryModel.self, MomentModel.self, StoryMomentLink.self, AssetModel.self,
                 GeneratedOutputModel.self, LocalIdentityModel.self,
                 MomentUnderstandingModel.self, AssetUnderstandingJobModel.self,
                 StoryCoverageModel.self, StoryGuideModel.self, StoryMusicDirectionModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func test_seededGuideIdea_showsInstantly_fromOpportunityText_noNetwork() throws {
        let container = try makeContainer()
        let story = StoryModel(title: "Girl in Dress", intentRawText: "cinematic dresses",
                               intentTheme: "t", intentTone: "o", intentSummary: "cinematic dresses")
        container.mainContext.insert(story)

        let opp = SelectedOpportunityDTO(
            storyGuideDimensionId: "dim_02", label: "Warm light on skin and fabric",
            purpose: "golden light wrapping the dress", capturePossibilityLabel: "Warm light on skin and fabric")

        let model = ContinuousCaptureModel()
        model.configure(context: container.mainContext, captureContext: .story(story), seedOpportunity: opp)
        // Before appear: no idea shown yet.
        XCTAssertEqual(model.aiState, .off)
        model.seedGuideIdeaIfNeeded()

        // Instantly in the .ideas state with THAT guide idea — no .thinking/.scanning, no Director call.
        XCTAssertEqual(model.aiState, .ideas)
        XCTAssertTrue(model.hasCachedIdeas)
        XCTAssertEqual(model.currentIdeaTitle, "Warm light on skin and fabric")
        XCTAssertEqual(model.currentIdeaBody, "golden light wrapping the dress")
        XCTAssertEqual(model.currentIdeaReminder, "Warm light on skin and fabric")
    }

    func test_noSeed_forPlainShootAMoment_showsPill() throws {
        let container = try makeContainer()
        let story = StoryModel(title: "S", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "x")
        container.mainContext.insert(story)

        let model = ContinuousCaptureModel()
        model.configure(context: container.mainContext, captureContext: .story(story), seedOpportunity: nil)
        model.seedGuideIdeaIfNeeded()

        XCTAssertEqual(model.aiState, .off)          // plain Shoot a moment: no seeded idea, pill shows
        XCTAssertFalse(model.hasCachedIdeas)
    }

    func test_seedConsumedOnce_reappearDoesNotReseed() throws {
        let container = try makeContainer()
        let story = StoryModel(title: "S", intentRawText: "x", intentTheme: "t", intentTone: "o", intentSummary: "x")
        container.mainContext.insert(story)
        let opp = SelectedOpportunityDTO(storyGuideDimensionId: "d", label: "Idea A",
                                         purpose: "p", capturePossibilityLabel: "Idea A")
        let model = ContinuousCaptureModel()
        model.configure(context: container.mainContext, captureContext: .story(story), seedOpportunity: opp)
        model.seedGuideIdeaIfNeeded()
        XCTAssertEqual(model.aiState, .ideas)
        // Simulate the user dismissing the overlay, then a view re-appear re-calling configure/seed.
        model.dismissIdeas()
        model.configure(context: container.mainContext, captureContext: .story(story), seedOpportunity: opp)
        model.seedGuideIdeaIfNeeded()
        // Seed is consumed once — re-appear must NOT force the idea overlay back open.
        XCTAssertNotEqual(model.aiState, .ideas)
    }
}

import XCTest
@testable import Story

// Director DTO decoding tests (Milestone C3B §11).
//
// Proves the Swift DirectorOutputDTO decodes the canonical backend envelope
// from POST /v1/director/initialize, that shot->beat references survive, and
// that a StoryModel maps back to the CreativeIntent wire contract the Director
// expects. No network — fixed JSON, same shape the backend emits.
final class DirectorDTOTests: XCTestCase {

    private let envelope = """
    {
      "concept": {"id":"11111111-1111-1111-1111-111111111111","title":"Preparation","summary":"The journey begins at home."},
      "plan": {
        "id":"22222222-2222-2222-2222-222222222222",
        "concept_id":"11111111-1111-1111-1111-111111111111",
        "beats":[{"id":"b_prep","purpose":"Show preparation."}],
        "shots":[{"id":"33333333-3333-3333-3333-333333333333","order":1,"beat_id":"b_prep",
                  "purpose":"Capture the packed bag.","instruction":"Film the backpack by the door.",
                  "camera_motion":"static","subject_action":"none","target_duration_seconds":3}]
      },
      "director_state": {"current_beat_id":"b_prep","beat_progress":[]},
      "decision": {"action":"capture_shot",
                   "shot":{"id":"33333333-3333-3333-3333-333333333333","order":1,"beat_id":"b_prep",
                           "purpose":"Capture the packed bag.","instruction":"Film the backpack by the door."}}
    }
    """.data(using: .utf8)!

    func testDecodesDirectorEnvelope() throws {
        let out = try StoryContractCoding.decoder().decode(DirectorOutputDTO.self, from: envelope)
        XCTAssertEqual(out.concept.title, "Preparation")
        XCTAssertEqual(out.plan.beats.count, 1)
        XCTAssertEqual(out.plan.shots.count, 1)
        // referential integrity survives the wire: shot -> real beat
        XCTAssertEqual(out.plan.shots[0].beatId, out.plan.beats[0].id)
        XCTAssertEqual(out.decision.action, .captureShot)
        // capture_shot carries a shot with a user-facing instruction
        XCTAssertEqual(out.decision.shot?.instruction, "Film the backpack by the door.")
        XCTAssertEqual(out.plan.shots[0].targetDurationSeconds, 3)
    }

    func testCreativeIntentMapsFromStory() throws {
        let story = StoryModel(
            title: "TMB", intentRawText: "8 days hiking in TMB",
            intentTheme: "adventure", intentTone: "peaceful",
            intentSummary: "8-day Tour du Mont Blanc hike")
        story.intentDesiredFeeling = ["peaceful", "adventurous"]
        story.intentEmphasis = ["journey"]
        story.intentPace = "slow"
        story.intentTargetDurationSeconds = 60

        let ci = CreativeIntentContractDTO(from: story)
        XCTAssertEqual(ci.summary, "8-day Tour du Mont Blanc hike")
        XCTAssertEqual(ci.desiredFeeling, ["peaceful", "adventurous"])
        XCTAssertEqual(ci.emphasis, ["journey"])
        XCTAssertEqual(ci.pace, .slow)
        XCTAssertEqual(ci.targetDurationSeconds, 60)
    }
}

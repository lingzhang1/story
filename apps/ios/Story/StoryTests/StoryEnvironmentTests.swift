import XCTest
@testable import Story

// TestFlight Option A — StoryEnvironment resolution + consistency guard (offline, pure).
//
// The RELEASE-only Info.plist-baked resolution and its fatalError paths cannot be exercised from a unit
// process (no archive, and a fatalError would kill the runner). What IS pure and testable is the
// consistency guard that the release resolver relies on and the hardcoded development default — so these
// lock the tripwire that decides "mixed dev/beta env => reject" and prove the dev default is internally
// consistent. The archive-level verification is the scripts/verify_beta_archive.sh pre-archive gate + the
// device "Beta build" acceptance step.
final class StoryEnvironmentTests: XCTestCase {

    func test_developmentDefault_isConsistent() throws {
        XCTAssertNoThrow(try StoryEnvironment.developmentDefault.assertConsistent())
        XCTAssertEqual(StoryEnvironment.developmentDefault.kind, .development)
        XCTAssertEqual(StoryEnvironment.developmentDefault.userPoolId, "us-east-1_AzfHOEdA5")
    }

    func test_betaLabel_withDevPool_isRejected() {
        // A beta-labelled env carrying the DEV Cognito pool is the exact "mixed" failure the gate must catch.
        let mixed = StoryEnvironment(
            kind: .beta,
            apiBaseURL: URL(string: "https://asxtxgjiis.us-east-1.awsapprunner.com")!,
            cognitoRegion: "us-east-1",
            userPoolId: "us-east-1_AzfHOEdA5",            // DEV pool — mismatch
            appClientId: "4f3dtn9d0nk5uq1hcvbdc7m73c",
            domainPrefix: "story-beta-auth",
            redirectURI: "story://auth")
        XCTAssertThrowsError(try mixed.assertConsistent())
    }

    func test_betaLabel_withDevApi_isRejected() {
        let mixed = StoryEnvironment(
            kind: .beta,
            apiBaseURL: URL(string: "https://ydmju5wdps.us-east-1.awsapprunner.com")!,  // DEV API — mismatch
            cognitoRegion: "us-east-1",
            userPoolId: "us-east-1_3cPNfbrUl",
            appClientId: "4f3dtn9d0nk5uq1hcvbdc7m73c",
            domainPrefix: "story-beta-auth",
            redirectURI: "story://auth")
        XCTAssertThrowsError(try mixed.assertConsistent())
    }

    func test_fullyBeta_isConsistent() throws {
        let beta = StoryEnvironment(
            kind: .beta,
            apiBaseURL: URL(string: "https://asxtxgjiis.us-east-1.awsapprunner.com")!,
            cognitoRegion: "us-east-1",
            userPoolId: "us-east-1_3cPNfbrUl",
            appClientId: "4f3dtn9d0nk5uq1hcvbdc7m73c",
            domainPrefix: "story-beta-auth",
            redirectURI: "story://auth")
        XCTAssertNoThrow(try beta.assertConsistent())
        XCTAssertEqual(beta.kind, .beta)
    }

    // The resolver that the app actually uses must at least produce an internally-consistent environment in
    // whatever configuration the test target builds (DEBUG) — i.e. it never hands back a mixed env.
    func test_current_isInternallyConsistent() throws {
        XCTAssertNoThrow(try StoryEnvironment.current.assertConsistent())
    }
}

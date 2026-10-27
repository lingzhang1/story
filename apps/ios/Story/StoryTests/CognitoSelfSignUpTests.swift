import XCTest
@testable import Story

// TestFlight Option A — unified passwordless email sign-up/sign-in (CognitoAuthClient).
//
// Network-free: a target-routing URLProtocol stub answers each Cognito IDP call by its `X-Amz-Target`
// header, so one test can script SignUp -> ConfirmSignUp -> InitiateAuth as a sequence. These lock the
// correct Cognito OPERATION per branch (the visual UX is shared, the operation must be exact) and the
// account-existence / recovery / error matrix, without a live pool and without weakening existing auth.
final class CognitoSelfSignUpTests: XCTestCase {

    private func makeClient() -> CognitoAuthClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CognitoRouteStub.self]
        return CognitoAuthClient(urlSession: URLSession(configuration: cfg))
    }

    override func setUp() { super.setUp(); CognitoRouteStub.reset() }
    override func tearDown() { CognitoRouteStub.reset(); super.tearDown() }

    // ---- new-user self-signup: SignUp succeeds -> .signUp challenge --------------------------------
    func test_newUser_signUp_returnsSignUpChallenge() async throws {
        CognitoRouteStub.on("SignUp", 200, #"{"CodeDeliveryDetails":{"Destination":"n***@e***.com"}}"#)
        let ch = try await makeClient().startEmailAuth(email: "New@Example.com")
        XCTAssertEqual(ch.kind, .signUp)
        XCTAssertEqual(ch.email, "new@example.com")                 // normalized
        XCTAssertEqual(ch.maskedDestination, "n***@e***.com")
    }

    // ---- existing user: SignUp -> UsernameExists -> falls through to EMAIL_OTP sign-in -------------
    func test_existingUser_fallsThroughToSignInChallenge() async throws {
        CognitoRouteStub.on("SignUp", 400, #"{"__type":"UsernameExistsException","message":"exists"}"#)
        CognitoRouteStub.on("InitiateAuth", 200, """
        {"ChallengeName":"EMAIL_OTP","Session":"sess-existing-0001",
         "ChallengeParameters":{"CODE_DELIVERY_DELIVERY_MEDIUM":"EMAIL","CODE_DELIVERY_DESTINATION":"e***@e***"}}
        """)
        let ch = try await makeClient().startEmailAuth(email: "existing@example.com")
        XCTAssertEqual(ch.kind, .signIn)
        XCTAssertEqual(ch.session, "sess-existing-0001")
    }

    // ---- new-user confirm: ConfirmSignUp returns Session -> USER_AUTH first sign-in (no 2nd code) --
    func test_confirmSignUp_thenSessionSignIn_returnsTokens() async throws {
        CognitoRouteStub.on("ConfirmSignUp", 200, #"{"Session":"confirm-session-which-is-long-enough-xx"}"#)
        CognitoRouteStub.on("InitiateAuth", 200, """
        {"AuthenticationResult":{"AccessToken":"acc","IdToken":"idt","RefreshToken":"ref","ExpiresIn":3600}}
        """)
        let ch = OTPChallenge(session: "", email: "new@example.com",
                              maskedDestination: "n***@e***", kind: .signUp)
        let tokens = try await makeClient().verifyCode("123456", challenge: ch)
        XCTAssertEqual(tokens.accessToken, "acc")
        XCTAssertEqual(tokens.idToken, "idt")
        XCTAssertEqual(tokens.refreshToken, "ref")
    }

    // ---- fallback: ConfirmSignUp returns NO usable session -> fresh OTP sign-in path signalled -----
    func test_confirmSignUp_noSession_fallsBackToStandardSignIn() async {
        CognitoRouteStub.on("ConfirmSignUp", 200, #"{}"#)              // no Session
        CognitoRouteStub.on("InitiateAuth", 200, """
        {"ChallengeName":"EMAIL_OTP","Session":"sess-fallback-000001",
         "ChallengeParameters":{"CODE_DELIVERY_DELIVERY_MEDIUM":"EMAIL","CODE_DELIVERY_DESTINATION":"n***@e***"}}
        """)
        let ch = OTPChallenge(session: "", email: "new@example.com",
                              maskedDestination: "n***@e***", kind: .signUp)
        await assertThrows(makeClient(), "123456", ch) {
            if case CognitoAuthError.noChallengeSession = $0 { return true }; return false
        }
    }

    // ---- existing-user EMAIL_OTP verify success ----------------------------------------------------
    func test_existingUser_verify_returnsTokens() async throws {
        CognitoRouteStub.on("RespondToAuthChallenge", 200, """
        {"AuthenticationResult":{"AccessToken":"a2","IdToken":"i2","RefreshToken":"r2","ExpiresIn":3600}}
        """)
        let ch = OTPChallenge(session: "sess-existing-0001", email: "existing@example.com",
                              maskedDestination: "e***@e***", kind: .signIn)
        let tokens = try await makeClient().verifyCode("654321", challenge: ch)
        XCTAssertEqual(tokens.accessToken, "a2")
    }

    // ---- wrong code: re-issued challenge (200, no AuthenticationResult) -> badCode ------------------
    func test_wrongCode_reissuedChallenge_isBadCode() async {
        CognitoRouteStub.on("RespondToAuthChallenge", 200, """
        {"ChallengeName":"EMAIL_OTP","Session":"again"}
        """)
        let ch = OTPChallenge(session: "s", email: "e@e.com", maskedDestination: "m", kind: .signIn)
        await assertThrows(makeClient(), "000000", ch) {
            if case CognitoAuthError.badCode = $0 { return true }; return false
        }
    }

    // ---- wrong code: CodeMismatchException -> badCode ----------------------------------------------
    func test_codeMismatch_isBadCode() async {
        CognitoRouteStub.on("RespondToAuthChallenge", 400, #"{"__type":"CodeMismatchException"}"#)
        let ch = OTPChallenge(session: "s", email: "e@e.com", maskedDestination: "m", kind: .signIn)
        await assertThrows(makeClient(), "000000", ch) {
            if case CognitoAuthError.badCode = $0 { return true }; return false
        }
    }

    // ---- expired code -> expiredCode ---------------------------------------------------------------
    func test_expiredCode_isExpiredCode() async {
        CognitoRouteStub.on("RespondToAuthChallenge", 400, #"{"__type":"ExpiredCodeException"}"#)
        let ch = OTPChallenge(session: "s", email: "e@e.com", maskedDestination: "m", kind: .signIn)
        await assertThrows(makeClient(), "000000", ch) {
            if case CognitoAuthError.expiredCode = $0 { return true }; return false
        }
    }

    // ---- throttling on confirm -> tooManyAttempts --------------------------------------------------
    func test_confirm_throttled_isTooManyAttempts() async {
        CognitoRouteStub.on("ConfirmSignUp", 400, #"{"__type":"TooManyFailedAttemptsException"}"#)
        let ch = OTPChallenge(session: "", email: "n@e.com", maskedDestination: "m", kind: .signUp)
        await assertThrows(makeClient(), "000000", ch) {
            if case CognitoAuthError.tooManyAttempts = $0 { return true }; return false
        }
    }

    // ---- resend for a new-user confirm uses ResendConfirmationCode (NOT InitiateAuth) --------------
    func test_resend_signUpChallenge_usesResendConfirmationCode() async throws {
        CognitoRouteStub.on("ResendConfirmationCode", 200, #"{"CodeDeliveryDetails":{"Destination":"n***"}}"#)
        let ch = OTPChallenge(session: "", email: "n@e.com", maskedDestination: "old", kind: .signUp)
        let refreshed = try await makeClient().resendCode(for: ch)
        XCTAssertEqual(refreshed.kind, .signUp)                       // still a confirm
        XCTAssertTrue(CognitoRouteStub.sawTarget("ResendConfirmationCode"))
        XCTAssertFalse(CognitoRouteStub.sawTarget("InitiateAuth"))
    }

    // ---- resend for a sign-in challenge re-runs InitiateAuth ---------------------------------------
    func test_resend_signInChallenge_rerunsInitiateAuth() async throws {
        CognitoRouteStub.on("InitiateAuth", 200, """
        {"ChallengeName":"EMAIL_OTP","Session":"fresh-session-00000001",
         "ChallengeParameters":{"CODE_DELIVERY_DELIVERY_MEDIUM":"EMAIL","CODE_DELIVERY_DESTINATION":"e***"}}
        """)
        let ch = OTPChallenge(session: "old", email: "e@e.com", maskedDestination: "m", kind: .signIn)
        let refreshed = try await makeClient().resendCode(for: ch)
        XCTAssertEqual(refreshed.kind, .signIn)
        XCTAssertEqual(refreshed.session, "fresh-session-00000001")
    }

    // ---- disabled/suspended account on start -> accountDisabled (no silent recreate) ---------------
    func test_disabledAccount_onStart_isAccountDisabled() async {
        CognitoRouteStub.on("SignUp", 400, #"{"__type":"UsernameExistsException"}"#)
        CognitoRouteStub.on("InitiateAuth", 400, #"{"__type":"NotAuthorizedException","message":"disabled"}"#)
        await assertThrowsStart(makeClient(), "disabled@example.com") {
            if case CognitoAuthError.accountDisabled = $0 { return true }; return false
        }
    }

    // ---- unknown-email decoy on the pure sign-in entry -> noOTPPath (no stranding) ------------------
    func test_signInEntry_noDeliveryMedium_isNoOTPPath() async {
        CognitoRouteStub.on("InitiateAuth", 200, #"{"ChallengeName":"SELECT_CHALLENGE"}"#)
        await assertThrowsSignIn(makeClient(), "unknown@example.com") {
            if case CognitoAuthError.noOTPPath = $0 { return true }; return false
        }
    }

    // ---- network failure surfaces as transport (or service wrapping transport) ---------------------
    func test_networkFailure_isTransportOrService() async {
        CognitoRouteStub.failWithNetworkError = true
        await assertThrowsStart(makeClient(), "x@example.com") {
            if case CognitoAuthError.transport = $0 { return true }
            if case CognitoAuthError.service = $0 { return true }
            return false
        }
    }

    // ---- helpers ----
    private func assertThrows(_ c: CognitoAuthClient, _ code: String, _ ch: OTPChallenge,
                              _ match: @escaping (Error) -> Bool,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await c.verifyCode(code, challenge: ch); XCTFail("expected throw", file: file, line: line) }
        catch { XCTAssertTrue(match(error), "unexpected: \(error)", file: file, line: line) }
    }
    private func assertThrowsStart(_ c: CognitoAuthClient, _ email: String,
                                   _ match: @escaping (Error) -> Bool,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await c.startEmailAuth(email: email); XCTFail("expected throw", file: file, line: line) }
        catch { XCTAssertTrue(match(error), "unexpected: \(error)", file: file, line: line) }
    }
    private func assertThrowsSignIn(_ c: CognitoAuthClient, _ email: String,
                                    _ match: @escaping (Error) -> Bool,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await c.startSignInOTP(email: email); XCTFail("expected throw", file: file, line: line) }
        catch { XCTAssertTrue(match(error), "unexpected: \(error)", file: file, line: line) }
    }
}

/// Routes each Cognito IDP call to a scripted response by its `X-Amz-Target` suffix (e.g. "SignUp"),
/// records which targets were seen, and can simulate a transport failure. One response per target is
/// enough for these flows (each target is hit at most once per test).
final class CognitoRouteStub: URLProtocol {
    struct Resp { let status: Int; let body: Data }
    nonisolated(unsafe) static var responses: [String: Resp] = [:]
    nonisolated(unsafe) static var seen: [String] = []
    nonisolated(unsafe) static var failWithNetworkError = false

    static func reset() { responses = [:]; seen = []; failWithNetworkError = false }
    static func on(_ target: String, _ status: Int, _ json: String) {
        responses[target] = Resp(status: status, body: Data(json.utf8))
    }
    static func sawTarget(_ target: String) -> Bool { seen.contains(target) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.failWithNetworkError {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let target = (request.value(forHTTPHeaderField: "X-Amz-Target") ?? "")
            .split(separator: ".").last.map(String.init) ?? ""
        Self.seen.append(target)
        let r = Self.responses[target] ?? Resp(status: 400, body: Data(#"{"__type":"UnknownOperation"}"#.utf8))
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

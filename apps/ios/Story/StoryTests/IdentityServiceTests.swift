import XCTest
@testable import Story

// R1.1 — canonical identity resolution (GET /v1/me) tests. Network-free via a URLProtocol stub, so these run
// in CI without a backend. They lock: (1) a 200 returns the canonical story_user_id; (2) 401 -> unauthorized;
// (3) non-2xx -> badStatus; (4) 200 with a missing/empty id -> missingId; (5) malformed JSON -> decoding.
// The AuthStore contract that a failed resolve FAILS sign-in (no sub/dev fallback) is enforced in finishSignIn
// and covered by the device acceptance matrix; here we lock the resolver these depend on.
final class IdentityServiceTests: XCTestCase {

    private func makeService(status: Int, body: Data) -> IdentityService {
        StubURLProtocol.status = status
        StubURLProtocol.body = body
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: cfg)
        return IdentityService(baseURL: URL(string: "https://example.test")!, session: session)
    }

    func test_resolve_success_returnsCanonicalId() async throws {
        let svc = makeService(status: 200, body: Data(#"{"story_user_id":"canon-123"}"#.utf8))
        let id = try await svc.resolveCanonicalId(accessToken: "tok")
        XCTAssertEqual(id, "canon-123")
    }

    func test_resolve_401_isUnauthorized() async {
        let svc = makeService(status: 401, body: Data(#"{"detail":"authentication required"}"#.utf8))
        await assertThrows(svc) { if case IdentityServiceError.unauthorized = $0 { return true }; return false }
    }

    func test_resolve_500_isBadStatus() async {
        let svc = makeService(status: 500, body: Data("oops".utf8))
        await assertThrows(svc) { if case IdentityServiceError.badStatus(500) = $0 { return true }; return false }
    }

    func test_resolve_missingId_isMissingId() async {
        let svc = makeService(status: 200, body: Data(#"{"story_user_id":"   "}"#.utf8))
        await assertThrows(svc) { if case IdentityServiceError.missingId = $0 { return true }; return false }
    }

    func test_resolve_malformedJson_isDecoding() async {
        let svc = makeService(status: 200, body: Data("not json".utf8))
        await assertThrows(svc) { if case IdentityServiceError.decoding = $0 { return true }; return false }
    }

    private func assertThrows(_ svc: IdentityService, _ match: (Error) -> Bool,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await svc.resolveCanonicalId(accessToken: "tok")
            XCTFail("expected throw", file: file, line: line)
        } catch {
            XCTAssertTrue(match(error), "unexpected error: \(error)", file: file, line: line)
        }
    }
}

/// Minimal URLProtocol stub for network-free IdentityService tests.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

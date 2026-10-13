import Foundation

// EditPlanJobClient — Phase 2 ASYNC Edit Planning client. Replaces the synchronous /v1/edit-plan[-mm] calls
// in Story creation with submit -> poll -> fetch against the durable job API (backend Phase 1). This removes
// the ~120s App Runner request ceiling: the backend returns a job id instantly and a Lambda worker runs the
// SAME plan/critique/validate core (frozen v5.2) for up to 15 min.
//
// Idempotency: the caller persists a stable operation_id BEFORE submitting. A duplicate submit (retry, dup
// tap, restart) with the SAME operation_id recovers the SAME job — never a second inference. A deliberate new
// version uses a NEW operation_id.

/// Terminal + transient job states mirrored from the backend contract.
enum EditPlanJobStatus: String {
    case queued, running, completed, failed, cancelled, expired, cancelRequested = "cancel_requested"
    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled || self == .expired }
}

/// Backend failure_category -> a user-distinguishable class (Phase 3 messaging).
enum EditPlanJobFailure: String {
    case providerExhausted = "provider_exhausted"
    case materialInfeasible = "material_infeasible"
    case invalidAfterRepair = "invalid_after_repair"
    case providerError = "provider_error"
    case enqueueLost = "enqueue_lost"
    case internalError = "internal"
    case unknown = ""
    static func from(_ raw: String?) -> EditPlanJobFailure { EditPlanJobFailure(rawValue: raw ?? "") ?? .unknown }
}

struct EditPlanJobState {
    let jobId: String
    let status: EditPlanJobStatus
    let plan: EditPlanV2?               // present only when completed
    let failure: EditPlanJobFailure?
    let failureDetail: String?
    let diagnostics: [String: JSONValue]?
}

enum EditPlanJobError: Error, LocalizedError {
    case transport(Error)               // network — SAFE to retry with the SAME operation_id
    case conflict                       // 409: same operation_id, different payload (client bug)
    case badStatus(Int)
    case decoding(Error)
    case pollTimeout                    // bounded polling elapsed without a terminal state (job may still run)

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach Story. Check your connection and try again."
        case .conflict: return "This Story is already being created."
        case .badStatus(let c): return "Unexpected response (\(c))."
        case .decoding: return "The plan response couldn't be read."
        case .pollTimeout: return "Still working on your Story — it's taking longer than usual."
        }
    }
}

final class EditPlanJobClient {
    private let baseURL: URL
    private let session: URLSession
    init(baseURL: URL = StoryBackend.baseURL, session: URLSession = StoryBackend.longSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Submit (idempotent on operation_id). Returns the job_id. A 409 means the same operation_id was used
    /// with a DIFFERENT payload — surfaced as .conflict, never silently retried.
    func submit(_ request: EditPlanRequestDTO, operationId: String, owner: String = "dev",
                approach: EditingApproach, sheets: [MomentContactSheet], creativeBrief: String?,
                critiqueRevision: Bool) async throws -> String {
        let boundary = "story.job.\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/edit-plan-jobs"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let bodyJSON: Data
        let orderJSON: Data
        let order = sheets.map { $0.momentId.uuidString }
        do {
            bodyJSON = try StoryContractCoding.encoder().encode(request)
            orderJSON = try JSONSerialization.data(withJSONObject: order)
        } catch { throw EditPlanJobError.transport(error) }

        var body = Data()
        func field(_ name: String, _ value: Data, contentType: String? = nil) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n".data(using: .utf8)!)
            if let contentType { body.append("Content-Type: \(contentType)\r\n".data(using: .utf8)!) }
            body.append("\r\n".data(using: .utf8)!)
            body.append(value); body.append("\r\n".data(using: .utf8)!)
        }
        field("operation_id", Data(operationId.utf8))
        field("owner", Data(owner.utf8))
        field("approach", Data(approach.rawValue.utf8))
        field("body", bodyJSON, contentType: "application/json")
        field("sheet_order", orderJSON, contentType: "application/json")
        if let creativeBrief { field("creative_brief", Data(creativeBrief.utf8)) }
        if critiqueRevision { field("critique_revision", Data("true".utf8)) }
        for s in sheets {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"sheets\"; filename=\"\(s.momentId.uuidString.lowercased()).jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(s.jpeg); body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        // Submit in a DETACHED task so a spurious cancellation of the caller's enclosing Task — e.g. SwiftUI
        // tearing down the view's `.task` on a re-render while the Creating screen is up — cannot abort an
        // in-flight submit with NSURLError -999 "cancelled" (observed on device). A REAL user cancel does not
        // rely on this: it goes through the coordinator's explicit cancel() -> backend cancel API. The POST is
        // small and bounded by the session's own 180s request timeout.
        let data: Data, resp: URLResponse
        let sendReq = req
        do {
            (data, resp) = try await Task.detached { [session] in try await session.data(for: sendReq) }.value
        } catch is CancellationError {
            throw EditPlanJobError.transport(URLError(.cancelled))
        } catch {
            throw EditPlanJobError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else { throw EditPlanJobError.badStatus(-1) }
        switch http.statusCode {
        case 202, 200:
            struct R: Decodable { let job_id: String }
            do { return try JSONDecoder().decode(R.self, from: data).job_id }
            catch { throw EditPlanJobError.decoding(error) }
        case 409: throw EditPlanJobError.conflict
        default: throw EditPlanJobError.badStatus(http.statusCode)
        }
    }

    /// One status read. Transport errors are SAFE (the job keeps running server-side); the caller retries.
    func status(jobId: String) async throws -> EditPlanJobState {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/edit-plan-jobs/\(jobId)"))
        req.httpMethod = "GET"
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw EditPlanJobError.transport(error) }
        guard let http = resp as? HTTPURLResponse else { throw EditPlanJobError.badStatus(-1) }
        guard http.statusCode == 200 else { throw EditPlanJobError.badStatus(http.statusCode) }
        struct R: Decodable {
            let job_id: String; let status: String
            let failure_category: String?; let failure_detail: String?
            let plan: EditPlanV2?; let diagnostics: [String: JSONValue]?
        }
        do {
            let r = try StoryContractCoding.decoder().decode(R.self, from: data)
            return EditPlanJobState(
                jobId: r.job_id, status: EditPlanJobStatus(rawValue: r.status) ?? .queued,
                plan: r.plan, failure: r.failure_category.map(EditPlanJobFailure.from),
                failureDetail: r.failure_detail, diagnostics: r.diagnostics)
        } catch { throw EditPlanJobError.decoding(error) }
    }

    /// Poll until terminal or the bounded budget elapses. Backoff is capped; a transport error does NOT end the
    /// poll (the job runs server-side) — it is retried. `shouldCancel` lets the caller stop polling (the job is
    /// cancelled via cancel()). The callbacks are @MainActor so a @MainActor caller can touch its isolated
    /// state in them (strict-concurrency safe). maxSeconds defaults to 900 (the worker's own ceiling).
    func pollUntilTerminal(jobId: String, maxSeconds: Int = 900,
                           shouldCancel: @MainActor () -> Bool = { false },
                           onState: @MainActor (EditPlanJobState) -> Void = { _ in }) async throws -> EditPlanJobState {
        let start = Date()
        var delay: UInt64 = 2
        while Date().timeIntervalSince(start) < Double(maxSeconds) {
            if await shouldCancel() { throw CancellationError() }
            do {
                let st = try await status(jobId: jobId)
                await onState(st)
                if st.status.isTerminal { return st }
            } catch EditPlanJobError.transport { /* keep polling — the job is unaffected */ }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 15)   // bounded exponential backoff, cap 15s
        }
        throw EditPlanJobError.pollTimeout
    }

    func cancel(jobId: String) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/edit-plan-jobs/\(jobId)/cancel"))
        req.httpMethod = "POST"
        _ = try? await session.data(for: req)   // best-effort; the backend finalizes cancelled
    }
}

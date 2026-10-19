import Foundation

// EditPlannerService — POST /v1/edit-plan (Milestone M-d / R-b Case G, frozen edit_plan/2).
//
// Builds the request from a Story's ALREADY-PERSISTED data (resolved CreativeIntent, completed
// MomentUnderstanding[]) and returns the backend's EditPlanV2 (one Opus 4.6 call under the server's
// DETERMINISTIC validator — an invalid plan is a 503, never a fabricated plan; infeasible material is a 422
// with a reason). MUSIC IS OPTIONAL: Case G runs in NO-MUSIC mode (no production MusicPlan engine exists),
// so music_plan/music_asset_id/music_analysis are omitted and the planner emits no music anchors.
//
// This service PLANS. It makes NO creative decisions and NO rendering decisions — the Media Engine renders
// the returned plan locally. No Epidemic, no provider credentials ever reach the device.

protocol EditPlanning {
    func plan(_ request: EditPlanRequestDTO) async throws -> EditPlanV2
    /// Plan with optional bounded contact-sheet visual evidence + a versioned creative brief. Default
    /// implementation ignores images and calls the text-only path, so a mock/alternate conformer need not
    /// implement multimodal to remain valid.
    func planMultimodal(_ request: EditPlanRequestDTO,
                        sheets: [MomentContactSheet],
                        creativeBrief: String?,
                        creativeBriefVersion: String?,
                        critiqueRevision: Bool) async throws -> MultimodalPlanOutcome
}

extension EditPlanning {
    func planMultimodal(_ request: EditPlanRequestDTO,
                        sheets: [MomentContactSheet],
                        creativeBrief: String?,
                        creativeBriefVersion: String?,
                        critiqueRevision: Bool = false) async throws -> MultimodalPlanOutcome {
        let plan = try await plan(request)
        return MultimodalPlanOutcome(plan: plan, usedMultimodal: false, sheetCount: 0, imageBytes: 0,
                                     fallbackReason: "multimodal_not_implemented",
                                     creativeBriefVersion: creativeBriefVersion)
    }
}

/// Outcome of a multimodal planning attempt — carries which path actually produced the plan, for diagnostics
/// and device-acceptance verification (so a device run can PROVE multimodal vs text-only was used).
struct MultimodalPlanOutcome {
    let plan: EditPlanV2
    let usedMultimodal: Bool
    let sheetCount: Int
    let imageBytes: Int
    let fallbackReason: String?     // nil when multimodal succeeded; else why it fell back to text-only
    let creativeBriefVersion: String?
}

// MARK: - Request DTO (mirrors the backend EditPlanRequest; snake_case wire)

struct EditPlanRequestDTO: Encodable {
    let storyId: UUID
    let creativeIntentId: UUID
    let creativeIntent: JSONValue          // resolved CreativeIntent incl. target_duration_seconds
    let storyGuide: JSONValue
    let storyCoverage: JSONValue
    let moments: [JSONValue]               // each: {id, duration_seconds, useful_segments:[[a,b],...]}
    let outputFormat: String               // vertical | square | landscape
    // Music is OPTIONAL (R-d). When present, the planner plans MUSIC-AWARE; when nil these keys are OMITTED
    // from the wire body so a no-music request is byte-identical to the device-verified R-c path.
    var musicPlan: JSONValue? = nil        // frozen music_plan/1
    var musicAssetId: String? = nil        // selected Epidemic track id
    var musicAnalysis: JSONValue? = nil    // frozen music_analysis/1 for the selected track
    var soundPreference: String? = nil     // immersive|balanced|music_led; nil omitted (no-music parity preserved)
    var editorialMode: String? = nil       // highlights|full|custom; nil omitted (back-compat, planner infers)
    // Creative Revision Foundation (additive, request-only). When present, carries the version-aware context
    // {mode, base_version_id, prior_edit_summaries, base_plan?, directives?, soft_direction?}. Lives INSIDE the
    // request body, so it is part of the frozen request snapshot AND the canonical async fingerprint (body-hashed)
    // with NO fingerprint-logic change. Omitted when nil => byte-identical to the pre-revision request.
    var revisionContext: JSONValue? = nil

    enum CodingKeys: String, CodingKey {
        case storyId = "story_id"
        case creativeIntentId = "creative_intent_id"
        case creativeIntent = "creative_intent"
        case storyGuide = "story_guide"
        case storyCoverage = "story_coverage"
        case moments
        case outputFormat = "output_format"
        case musicPlan = "music_plan"
        case musicAssetId = "music_asset_id"
        case musicAnalysis = "music_analysis"
        case soundPreference = "sound_preference"
        case editorialMode = "editorial_mode"
        case revisionContext = "revision_context"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(storyId, forKey: .storyId)
        try c.encode(creativeIntentId, forKey: .creativeIntentId)
        try c.encode(creativeIntent, forKey: .creativeIntent)
        try c.encode(storyGuide, forKey: .storyGuide)
        try c.encode(storyCoverage, forKey: .storyCoverage)
        try c.encode(moments, forKey: .moments)
        try c.encode(outputFormat, forKey: .outputFormat)
        // Omit music keys entirely when nil (no-music parity).
        if let musicPlan { try c.encode(musicPlan, forKey: .musicPlan) }
        if let musicAssetId { try c.encode(musicAssetId, forKey: .musicAssetId) }
        if let musicAnalysis { try c.encode(musicAnalysis, forKey: .musicAnalysis) }
        if let soundPreference { try c.encode(soundPreference, forKey: .soundPreference) }
        if let editorialMode { try c.encode(editorialMode, forKey: .editorialMode) }
        if let revisionContext { try c.encode(revisionContext, forKey: .revisionContext) }
    }
}

enum EditPlannerServiceError: Error, LocalizedError {
    case transport(Error)
    case unavailable            // 503 — model/validation failure; the server refused to fabricate a plan
    case infeasible(String)     // 422 — material can't reach target; carries the server's reason
    case badStatus(Int)
    case decoding(Error)
    /// An IMAGE-input rejection from /v1/edit-plan-mm (413/415, or an image-mapping 422). Carries the HTTP
    /// status AND the server's verbatim `detail` so the device can record WHY multimodal fell back instead
    /// of a generic code — the whole point of the 422 diagnostics. This triggers the text-only fallback.
    case imageRejected(code: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .transport: return "Couldn't reach the Edit Planner. Check your connection and try again."
        case .unavailable: return "The Edit Planner is temporarily unavailable. Please retry."
        case .infeasible(let r): return "This Story's material can't fill the target: \(r)"
        case .badStatus(let c): return "Unexpected response (\(c))."
        case .decoding: return "The plan response couldn't be read."
        case .imageRejected(let c, let d): return "Visual evidence rejected (\(c)): \(d)"
        }
    }
}

final class EditPlannerService: EditPlanning {
    private let baseURL: URL
    private let session: URLSession
    init(baseURL: URL = StoryBackend.baseURL, session: URLSession = StoryBackend.longSession) {
        self.baseURL = baseURL
        self.session = session
    }

    func plan(_ request: EditPlanRequestDTO) async throws -> EditPlanV2 {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/edit-plan"))
        StoryBackend.authorize(&req)  // P0 auth seam: bearer token when signed in
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { req.httpBody = try StoryContractCoding.encoder().encode(request) }
        catch { throw EditPlannerServiceError.transport(error) }

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw EditPlannerServiceError.transport(error) }

        guard let http = resp as? HTTPURLResponse else { throw EditPlannerServiceError.badStatus(-1) }
        switch http.statusCode {
        case 200:
            do { return try StoryContractCoding.decoder().decode(EditPlanV2.self, from: data) }
            catch { throw EditPlannerServiceError.decoding(error) }
        case 422:
            throw EditPlannerServiceError.infeasible(Self.detail(data))
        case 503:
            throw EditPlannerServiceError.unavailable
        default:
            throw EditPlannerServiceError.badStatus(http.statusCode)
        }
    }

    private static func detail(_ data: Data) -> String {
        (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
            ?? String(data: data, encoding: .utf8) ?? "infeasible"
    }

    // MARK: - MVP multimodal planning (/v1/edit-plan-mm) with graceful text-only fallback

    /// Plan WITH bounded contact-sheet visual evidence. On an IMAGE-INPUT failure (413 payload/size, 415 type,
    /// an image-mapping 422, or a transport error while sending images) this falls back to the frozen text-only
    /// /v1/edit-plan path — never fabricating evidence, never dropping a Moment. A 503 (model) or a genuine
    /// MATERIAL 422 (infeasible footage) is NOT an image problem and is surfaced as-is (no silent retry).
    func planMultimodal(_ request: EditPlanRequestDTO,
                        sheets: [MomentContactSheet],
                        creativeBrief: String?,
                        creativeBriefVersion: String?,
                        critiqueRevision: Bool = false) async throws -> MultimodalPlanOutcome {
        // No sheets -> there is nothing multimodal to send; use the text-only path directly.
        guard !sheets.isEmpty else {
            let plan = try await plan(request)
            return MultimodalPlanOutcome(plan: plan, usedMultimodal: false, sheetCount: 0, imageBytes: 0,
                                         fallbackReason: "no_sheets", creativeBriefVersion: creativeBriefVersion)
        }
        let order = sheets.map { $0.momentId.uuidString }
        let imageBytes = sheets.reduce(0) { $0 + $1.jpeg.count }
        do {
            let plan = try await sendMultipart(request, sheets: sheets, sheetOrder: order,
                                               creativeBrief: creativeBrief, critiqueRevision: critiqueRevision)
            return MultimodalPlanOutcome(plan: plan, usedMultimodal: true, sheetCount: sheets.count,
                                         imageBytes: imageBytes, fallbackReason: nil,
                                         creativeBriefVersion: creativeBriefVersion)
        } catch let EditPlannerServiceError.imageRejected(code, detail) {
            // Image size/type/mapping rejection -> text-only fallback. Record the server's VERBATIM reason
            // (truncated) so lastPlanningDiagnostics reveals EXACTLY why multimodal fell back — not a generic
            // code. This is the device half of the 422 diagnostics.
            let plan = try await plan(request)
            let reason = "image_rejected_\(code): \(detail.prefix(160))"
            return MultimodalPlanOutcome(plan: plan, usedMultimodal: false, sheetCount: sheets.count,
                                         imageBytes: imageBytes, fallbackReason: reason,
                                         creativeBriefVersion: creativeBriefVersion)
        } catch let EditPlannerServiceError.transport(err) {
            // A transport error while sending the larger image payload -> try text-only once.
            let plan = try await plan(request)
            return MultimodalPlanOutcome(plan: plan, usedMultimodal: false, sheetCount: sheets.count,
                                         imageBytes: imageBytes,
                                         fallbackReason: "transport:\(String(describing: err).prefix(60))",
                                         creativeBriefVersion: creativeBriefVersion)
        }
        // NOTE: .unavailable (503) and .infeasible (422 material) deliberately propagate — not image problems.
    }

    private func sendMultipart(_ request: EditPlanRequestDTO,
                               sheets: [MomentContactSheet],
                               sheetOrder: [String],
                               creativeBrief: String?,
                               critiqueRevision: Bool = false) async throws -> EditPlanV2 {
        let boundary = "story.mm.\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/edit-plan-mm"))
        StoryBackend.authorize(&req)  // P0 auth seam: bearer token when signed in
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let bodyJSON: Data
        let orderJSON: Data
        do {
            bodyJSON = try StoryContractCoding.encoder().encode(request)
            orderJSON = try JSONSerialization.data(withJSONObject: sheetOrder)
        } catch { throw EditPlannerServiceError.transport(error) }

        var body = Data()
        func field(_ name: String, _ value: Data, contentType: String? = nil) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n".data(using: .utf8)!)
            if let contentType { body.append("Content-Type: \(contentType)\r\n".data(using: .utf8)!) }
            body.append("\r\n".data(using: .utf8)!)
            body.append(value)
            body.append("\r\n".data(using: .utf8)!)
        }
        func fileField(_ name: String, filename: String, _ value: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(value)
            body.append("\r\n".data(using: .utf8)!)
        }
        field("body", bodyJSON, contentType: "application/json")
        field("sheet_order", orderJSON, contentType: "application/json")
        if let creativeBrief { field("creative_brief", Data(creativeBrief.utf8)) }
        if critiqueRevision { field("critique_revision", Data("true".utf8)) }
        // One file part per sheet, in sheetOrder — order is preserved by multipart part ordering.
        for s in sheets {
            fileField("sheets", filename: "\(s.momentId.uuidString.lowercased()).jpg", s.jpeg)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw EditPlannerServiceError.transport(error) }
        guard let http = resp as? HTTPURLResponse else { throw EditPlannerServiceError.badStatus(-1) }
        switch http.statusCode {
        case 200:
            do { return try StoryContractCoding.decoder().decode(EditPlanV2.self, from: data) }
            catch { throw EditPlannerServiceError.decoding(error) }
        case 422:
            // Distinguish an IMAGE-mapping 422 (fall back, carrying the reason) from a MATERIAL 422 (surface).
            // The server uses distinct detail text: image-mapping says "contact sheet"/"sheet_order"/"unknown
            // Moment id"; material says "infeasible". Carry the VERBATIM detail either way for diagnostics.
            let full = Self.detail(data)
            let d = full.lowercased()
            if d.contains("sheet") || d.contains("unknown moment id") || d.contains("image") {
                throw EditPlannerServiceError.imageRejected(code: 422, detail: full)
            }
            throw EditPlannerServiceError.infeasible(full)
        case 413, 415:
            throw EditPlannerServiceError.imageRejected(code: http.statusCode, detail: Self.detail(data))
        case 503:
            throw EditPlannerServiceError.unavailable
        default:
            throw EditPlannerServiceError.badStatus(http.statusCode)
        }
    }
}
